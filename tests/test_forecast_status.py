# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""The forecast collection's heartbeat (scripts/forecast_status.py), on a local forecast
repository and a local published file."""

import importlib.util
import json
import pathlib
import re
import tomllib

import icechunk
import numpy as np
import pandas as pd
import pytest
import xarray as xr

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "forecast_status.py"
spec = importlib.util.spec_from_file_location("forecast_status", SCRIPT)
assert spec is not None and spec.loader is not None
forecast_status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(forecast_status)


def forecast_repository(path: pathlib.Path, runs: list[str], glo12: list[bool]) -> None:
  """A forecast repository as arco-make writes it: runs along init_time, 3 lead days, two flags
  (GLO12's given per lead day of the newest run) and a variable."""
  init = pd.to_datetime(runs).values
  lead = pd.to_timedelta([0, 1, 2], unit="D").values
  shape = (len(init), len(lead))
  glo12_flag = np.ones(shape, dtype=bool)
  glo12_flag[-1] = glo12
  dataset = xr.Dataset(
    {
      "thetao": (("init_time", "lead_time"), np.zeros(shape, dtype="float32")),
      "ifs_forecast": (("init_time", "lead_time"), np.ones(shape, dtype=bool)),
      "glo12_forecast": (("init_time", "lead_time"), glo12_flag),
      "lsm": ((), np.float32(0.5)),
    },
    coords={"init_time": init, "lead_time": lead},
  )
  repo = icechunk.Repository.create(icechunk.local_filesystem_storage(str(path)))
  session = repo.writable_session("main")
  dataset.to_zarr(session.store, mode="w", consolidated=False)
  session.commit("forecast")


def run(state: pathlib.Path, published: pathlib.Path, *args: str) -> dict:
  assert forecast_status.main(["--state-file", str(state), "--publish", str(published), *args]) == 0
  return json.loads(published.read_text())


@pytest.fixture
def files(tmp_path: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
  return tmp_path / "logs" / "status.json", tmp_path / "www" / "forecast.json"


def test_a_collection_from_start_to_end(tmp_path, files) -> None:
  state, published = files
  repo = tmp_path / "forecast" / "res=1p0"
  forecast_repository(repo, ["2026-11-22", "2026-11-23"], [False, True, True])
  missing = tmp_path / "forecast" / "res=0p5"

  document = run(
    state, published, "start", "--target-run", "2026-11-24",
    "--repo", f"1p0={repo}", "--repo", f"0p5={missing}",
  )  # fmt: skip
  assert document["schema"] == 1
  assert document["state"] == "running"
  assert document["target_run"] == "2026-11-24"
  assert document["heartbeat_seconds"] == 300
  assert document["stale_after_hours"] == 30.0
  # Local paths are not published; the state file keeps them.
  assert "repositories" not in document
  assert str(repo) not in published.read_text()
  assert json.loads(state.read_text())["repositories"]["1p0"] == str(repo)
  one, half = document["resolutions"]
  assert one["res"] == "1p0" and one["state"] == "pending"
  assert one["latest_run"] == "2026-11-23" and one["runs"] == 2
  # The share of the newest run's lead times that are its own forecast; `lsm`, `thetao` are no
  # flags.
  assert one["flags"] == {"ifs_forecast": 1.0, "glo12_forecast": pytest.approx(0.667)}
  assert half["latest_run"] is None and half["runs"] is None and half["flags"] == {}

  document = run(state, published, "res", "1p0", "downloading")
  assert document["resolutions"][0]["state"] == "downloading"
  assert document["resolutions"][0]["started_at"] is not None

  # The run of the 24th is stored by the download.
  forecast_repository(
    tmp_path / "next", ["2026-11-22", "2026-11-23", "2026-11-24"], [True, True, True]
  )
  repo.rename(tmp_path / "old")
  (tmp_path / "next").rename(repo)
  document = run(state, published, "res", "1p0", "finished")
  assert document["resolutions"][0]["state"] == "finished"
  assert document["resolutions"][0]["latest_run"] == "2026-11-24"
  assert document["resolutions"][0]["runs"] == 3
  assert document["resolutions"][0]["flags"]["glo12_forecast"] == 1.0

  document = run(state, published, "beat")
  assert document["state"] == "running"

  document = run(state, published, "end", "finished")
  assert document["state"] == "finished"
  assert document["ended_at"] is not None
  ended = published.read_text()

  # A late beat does not bring an ended collection back to life.
  run(state, published, "beat")
  assert published.read_text() == ended


def test_an_aborted_collection_fails_the_resolution_downloading(files) -> None:
  state, published = files
  run(state, published, "start", "--target-run", "2026-11-24", "--repo", "1p0=/nowhere")
  run(state, published, "res", "1p0", "downloading")
  document = run(state, published, "end", "aborted", "--detail", "Killed.")
  assert document["state"] == "aborted"
  assert document["detail"] == "Killed."
  assert document["resolutions"][0]["state"] == "failed"


def test_only_an_aborted_collection_fails_the_resolution_downloading(files) -> None:
  state, published = files
  run(state, published, "start", "--target-run", "2026-11-24", "--repo", "1p0=/nowhere")
  run(state, published, "res", "1p0", "downloading")
  document = run(state, published, "end", "finished")
  assert document["resolutions"][0]["state"] == "downloading"


def test_a_new_collection_keeps_the_newest_runs_known(tmp_path, files, monkeypatch) -> None:
  state, published = files
  repo = tmp_path / "res=1p0"
  forecast_repository(repo, ["2026-11-23"], [True, True, True])
  run(state, published, "start", "--target-run", "2026-11-23", "--repo", f"1p0={repo}")
  run(state, published, "end", "finished")

  # The repository cannot be read at the next start (S3 down, say): what was known stays, with
  # the error, which names no path.
  def unreadable(path: str) -> dict:
    raise OSError(f"cannot reach {path}")

  monkeypatch.setattr(forecast_status, "repository_summary", unreadable)
  document = run(state, published, "start", "--target-run", "2026-11-24", "--repo", f"1p0={repo}")
  entry = document["resolutions"][0]
  assert entry["latest_run"] == "2026-11-23"
  assert entry["error"] is not None and str(repo) not in entry["error"]
  assert document["state"] == "running" and document["ended_at"] is None


def test_steps_need_a_started_collection(files) -> None:
  state, published = files
  with pytest.raises(SystemExit, match="no collection started"):
    forecast_status.main(["--state-file", str(state), "beat"])
  run(state, published, "start", "--target-run", "2026-11-24", "--repo", "1p0=/nowhere")
  with pytest.raises(SystemExit, match="unknown resolution"):
    forecast_status.main(["--state-file", str(state), "res", "0p25", "finished"])


def test_a_resolution_waits_from_its_first_collection_not_published(files) -> None:
  state, published = files

  def collection(target: str, outcome: str) -> dict:
    run(state, published, "start", "--target-run", target, "--repo", "1p0=/nowhere")
    run(state, published, "res", "1p0", "downloading")
    run(state, published, "res", "1p0", outcome)
    return run(state, published, "end", "finished")["resolutions"][0]

  first = collection("2026-11-22", "not_published")
  assert first["waiting_since"] is not None
  # Still waiting the next day: since the first; a failure changes nothing; stored, it stops.
  assert collection("2026-11-23", "not_published")["waiting_since"] == first["waiting_since"]
  assert collection("2026-11-24", "failed")["waiting_since"] == first["waiting_since"]
  assert collection("2026-11-25", "finished")["waiting_since"] is None


def test_the_published_missing_after_is_the_recipes(files) -> None:
  # The page judges lags and waits by it: forecast.sh's default must be the recipes' value.
  root = pathlib.Path(__file__).parents[1]
  script = (root / "scripts" / "forecast.sh").read_text()
  match = re.search(r"^MISSING_AFTER=([0-9.]+)$", script, re.MULTILINE)
  assert match is not None
  default = float(match.group(1))
  recipes = sorted((root / "configs" / "download").glob("forecast_res-*.toml"))
  assert recipes
  for recipe in recipes:
    value = tomllib.loads(recipe.read_text())["forecast"]["missing_after"]
    assert pd.to_timedelta(value) == pd.Timedelta(days=default), recipe.name
  state, published = files
  document = run(
    state, published, "start", "--target-run", "2026-11-24", "--missing-after-days", "2"
  )
  assert document["missing_after_days"] == 2.0
