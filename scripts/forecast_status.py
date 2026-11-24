# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""The forecast collection's heartbeat: a JSON document that the ARCO-OCEAN web page reads.

`scripts/forecast.sh` calls this script at each step of a collection, and every few minutes while
it runs. Each call updates a local state file and, with `--publish`, uploads the document (to an
`s3://` URL, through the AWS profile of arco-make's settings, or to a local path). The page tells
from it whether the latest collection is running, finished or aborted, and calls it stale when
the heartbeat stops or no collection finished for too long: a collection killed without notice
(the machine down, a signal that cannot be trapped) stops beating.

The document (`SCHEMA` 1), all times in UTC:

  {"schema": 1, "state": "running" | "finished" | "aborted", "detail": str | null,
   "started_at": time, "updated_at": time (the heartbeat), "ended_at": time | null,
   "heartbeat_seconds": int, "stale_after_hours": float, "target_run": "YYYY-MM-DD",
   "resolutions": [{"res": "0p25", "state": "pending" | "downloading" | "finished"
                    | "not_published" | "failed", "started_at": ..., "ended_at": ...,
                    "latest_run": "YYYY-MM-DD" | null, "runs": int | null,
                    "flags": {flag variable: fraction of the latest run's lead times true},
                    "error": str | null}]}

Local paths stay in the state file: they are not published.

Usage (from scripts/forecast.sh; run with the Python of the arco-make that downloads):
  forecast_status.py --state-file F [--publish URL] start --target-run DATE --repo RES=PATH ...
  forecast_status.py --state-file F [--publish URL] beat
  forecast_status.py --state-file F [--publish URL] res RES STATE
  forecast_status.py --state-file F [--publish URL] end STATE [--detail TEXT]
"""

import argparse
import contextlib
import datetime
import fcntl
import json
import os
import pathlib
import sys
import tempfile
from collections.abc import Iterator
from typing import Any

SCHEMA = 1
STATES = ("running", "finished", "aborted")
RES_STATES = ("pending", "downloading", "finished", "not_published", "failed")
# Dimensions of the forecast recipes (arco-make's defaults).
INIT_DIM = "init_time"
LEAD_DIM = "lead_time"
# Not published: the repositories' local paths.
PRIVATE_KEYS = ("repositories",)


def now() -> str:
  return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


@contextlib.contextmanager
def locked(state_file: pathlib.Path) -> Iterator[None]:
  """The heartbeat loop and the steps of the collection update the state file in turn."""
  lock = state_file.with_name(state_file.name + ".lock")
  lock.parent.mkdir(parents=True, exist_ok=True)
  with lock.open("w") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    yield


def load(state_file: pathlib.Path) -> dict[str, Any] | None:
  try:
    return json.loads(state_file.read_text())
  except FileNotFoundError:
    return None


def write_atomically(path: pathlib.Path, text: str) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp") as tmp:
    tmp.write(text)
  os.replace(tmp.name, path)


def public(document: dict[str, Any]) -> str:
  shown = {key: value for key, value in document.items() if key not in PRIVATE_KEYS}
  return json.dumps(shown, indent=2) + "\n"


def publish(url: str, body: str) -> None:
  """Upload `body` to an `s3://` URL (never cached by browsers: the page polls it), or write it
  to a local path."""
  if not url.startswith("s3://"):
    write_atomically(pathlib.Path(url), body)
    return
  import botocore.session
  from arcomake import settings

  # The AWS profile and other settings from ~/.arcomakerc, as arco-make itself reads them.
  settings.apply(settings.read(settings.settings_path()))
  bucket, _, key = url.removeprefix("s3://").partition("/")
  if not bucket or not key:
    raise ValueError(f"not an object URL: {url}")
  session = botocore.session.Session()
  # botocore follows S3's redirect to the bucket's region, whatever the profile's.
  region = session.get_config_variable("region") or "us-east-1"
  client = session.create_client("s3", region_name=region)
  client.put_object(
    Bucket=bucket,
    Key=key,
    Body=body.encode(),
    ContentType="application/json",
    CacheControl="no-cache, max-age=0",
  )


def repository_summary(path: str) -> dict[str, Any]:
  """The newest run in the forecast repository at `path` (on `main`), the number of runs, and,
  for each flag variable (bool, init x lead), the fraction of that run's lead times flagged."""
  import xarray as xr
  from arcomake import icechunk_utils

  if not icechunk_utils.is_repository(path):
    return {"latest_run": None, "runs": None, "flags": {}}
  dataset = xr.open_zarr(icechunk_utils.readonly_store(path), consolidated=False)
  init = dataset[INIT_DIM]
  if init.size == 0:
    return {"latest_run": None, "runs": 0, "flags": {}}
  latest = init.values.max()
  flags = {
    str(name): round(float(variable.sel({INIT_DIM: latest}).mean()), 3)
    for name, variable in dataset.data_vars.items()
    if variable.dtype == bool and set(variable.dims) == {INIT_DIM, LEAD_DIM}
  }
  day = str(latest.astype("datetime64[D]"))
  return {"latest_run": day, "runs": int(init.size), "flags": flags}


def summarize(entry: dict[str, Any], path: str | None) -> None:
  """Add the repository's summary to a resolution's entry; a failure is recorded, not raised:
  the heartbeat never stops a collection."""
  if path is None:
    return
  try:
    entry.update(repository_summary(path))
    entry["error"] = None
  except Exception as error:  # noqa: BLE001 (reported in the document)
    entry["error"] = f"the repository could not be read: {type(error).__name__}"


def start(document: dict[str, Any] | None, args: argparse.Namespace) -> dict[str, Any]:
  repositories = dict(item.split("=", 1) for item in args.repo)
  previous = {entry["res"]: entry for entry in (document or {}).get("resolutions", [])}
  resolutions = []
  for res, path in repositories.items():
    entry = {
      "res": res,
      "state": "pending",
      "started_at": None,
      "ended_at": None,
      "latest_run": previous.get(res, {}).get("latest_run"),
      "runs": previous.get(res, {}).get("runs"),
      "flags": previous.get(res, {}).get("flags", {}),
      "error": None,
    }
    summarize(entry, path)
    resolutions.append(entry)
  return {
    "schema": SCHEMA,
    "state": "running",
    "detail": None,
    "started_at": now(),
    "updated_at": now(),
    "ended_at": None,
    "heartbeat_seconds": args.heartbeat_seconds,
    "stale_after_hours": args.stale_after_hours,
    "target_run": args.target_run,
    "resolutions": resolutions,
    "repositories": repositories,
  }


def resolution(document: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
  entries = {entry["res"]: entry for entry in document["resolutions"]}
  if args.res not in entries:
    raise SystemExit(f"unknown resolution {args.res!r}: not in this collection")
  entry = entries[args.res]
  entry["state"] = args.state
  if args.state == "downloading":
    entry["started_at"] = now()
  elif args.state != "pending":
    entry["ended_at"] = now()
    summarize(entry, document.get("repositories", {}).get(args.res))
  return document


def end(document: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
  document["state"] = args.state
  document["detail"] = args.detail
  document["ended_at"] = now()
  for entry in document["resolutions"]:
    # A collection aborted while a resolution was downloading: that one failed.
    if args.state == "aborted" and entry["state"] == "downloading":
      entry["state"] = "failed"
      entry["ended_at"] = now()
  return document


def parse(argv: list[str]) -> argparse.Namespace:
  parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
  parser.add_argument("--state-file", type=pathlib.Path, required=True)
  parser.add_argument("--publish", help="s3:// URL or local path of the published document")
  commands = parser.add_subparsers(dest="command", required=True)
  first = commands.add_parser("start", help="a collection starts")
  first.add_argument("--target-run", required=True, help="the newest run asked for (YYYY-MM-DD)")
  first.add_argument("--repo", action="append", default=[], help="RES=PATH, one per resolution")
  first.add_argument("--heartbeat-seconds", type=int, default=300)
  first.add_argument("--stale-after-hours", type=float, default=30.0)
  commands.add_parser("beat", help="the collection is still running")
  step = commands.add_parser("res", help="a resolution's download changes state")
  step.add_argument("res")
  step.add_argument("state", choices=RES_STATES)
  last = commands.add_parser("end", help="the collection ends")
  last.add_argument("state", choices=STATES[1:])
  last.add_argument("--detail")
  return parser.parse_args(argv)


def main(argv: list[str]) -> int:
  args = parse(argv)
  with locked(args.state_file):
    document = load(args.state_file)
    if args.command == "start":
      document = start(document, args)
    elif document is None:
      raise SystemExit(f"no collection started: {args.state_file} is missing")
    elif args.command == "res":
      document = resolution(document, args)
    elif args.command == "end":
      document = end(document, args)
    elif document["state"] != "running":
      # A late beat of an ended collection would make it look as if it were running again.
      return 0
    document["updated_at"] = now()
    write_atomically(args.state_file, json.dumps(document, indent=2) + "\n")
    if args.publish:
      publish(args.publish, public(document))
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
