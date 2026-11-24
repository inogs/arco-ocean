# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""scripts/download.sh's attempts, with a stand-in for arco-make (in a --virtual-env)."""

import os
import pathlib
import shutil
import subprocess
import sys
import time

import pytest

SCRIPTS = pathlib.Path(__file__).parents[1] / "scripts"

# Records its arguments; refuses, as arco-make does, a run while a failed one waits, unless
# resumed.
FAKE_ARCO_MAKE = """#!/usr/bin/env bash
echo "$*" >> "${CALLS}"
if [[ " $* " == *" --resume "* ]]; then exit 0; fi
echo "Error: A download run failed at out (run/download-extend-x, 3 blocks written):" \\
    "--extend --resume continues it; --replace (without --extend) rewrites the output"
exit 1
"""

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="needs Linux (date -d)")


@pytest.fixture
def project(tmp_path: pathlib.Path) -> pathlib.Path:
  (tmp_path / "scripts").mkdir()
  shutil.copy(SCRIPTS / "download.sh", tmp_path / "scripts" / "download.sh")
  (tmp_path / "configs" / "download").mkdir(parents=True)
  (tmp_path / "configs" / "download" / "forecast_res-1p0.toml").write_text("")
  arco_make = tmp_path / "venv" / "bin" / "arco-make"
  arco_make.parent.mkdir(parents=True)
  arco_make.write_text(FAKE_ARCO_MAKE)
  arco_make.chmod(0o755)
  return tmp_path


def test_a_run_refused_for_a_failed_one_resumes_it_at_once(project: pathlib.Path):
  calls = project / "calls"
  begun = time.monotonic()
  result = subprocess.run(
    [
      "bash", str(project / "scripts" / "download.sh"), "--project-dir", str(project),
      "--virtual-env", str(project / "venv"), "--env-file", "", "--extend",
      "--end", "2026-11-25", "--attempts", "3", "--retry-delay", "600", "forecast_res-1p0",
    ],
    env={**os.environ, "CALLS": str(calls), "DATA_ROOT": str(project)},
    capture_output=True,
    text=True,
    timeout=120,
  )  # fmt: skip
  assert result.returncode == 0, result.stdout + result.stderr
  # Not after the 600 s between attempts.
  assert time.monotonic() - begun < 60
  first, second = calls.read_text().splitlines()
  assert "--extend" in first and "--resume" not in first
  assert "--extend" in second and "--resume" in second
  assert "an earlier run failed and waits: resuming it" in result.stdout
