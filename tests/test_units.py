# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""The systemd user units (systemd/), their installer (scripts/install_units.sh) and the
watchdog's keepalive (scripts/keep_watchdog_enabled.sh), with stand-ins for systemctl, loginctl
and gh that record their calls."""

import os
import pathlib
import shutil
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).parents[1]
UNITS = sorted((ROOT / "systemd").iterdir())

# Records its arguments, one call per line; gh answers FAKE_STATE to the workflow's state.
RECORDER = """#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "${CALLS}"
if [[ "$(basename "$0")" == loginctl ]]; then echo "${FAKE_LINGER:-no}"; fi
if [[ "$(basename "$0")" == gh && "$*" == *"--jq .state"* ]]; then echo "${FAKE_STATE}"; fi
if [[ "$(basename "$0")" == gh && -n "${GH_TOKEN:-}" ]]; then echo "token ${GH_TOKEN}" >> "${CALLS}.env"; fi
exit 0
"""

pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="systemd units: Linux only")


@pytest.fixture
def fake(tmp_path: pathlib.Path) -> dict[str, str]:
  bin_dir = tmp_path / "bin"
  bin_dir.mkdir()
  for name in ("systemctl", "loginctl", "gh"):
    (bin_dir / name).write_text(RECORDER)
    (bin_dir / name).chmod(0o755)
  return {
    "PATH": f"{bin_dir}:/usr/bin:/bin",
    "HOME": str(tmp_path / "home"),
    "XDG_CONFIG_HOME": str(tmp_path / "config"),
    "USER": "someone",
    "CALLS": str(tmp_path / "calls"),
  }


def run(script: str, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
  return subprocess.run(
    ["bash", str(ROOT / "scripts" / script), *args],
    env=env,
    capture_output=True,
    text=True,
  )


def calls(env: dict[str, str]) -> list[str]:
  path = pathlib.Path(env["CALLS"])
  return path.read_text().splitlines() if path.exists() else []


def test_units_carry_no_machine_paths():
  # The machine's part (checkout, options) goes into drop-ins, written at install.
  for unit in UNITS:
    text = unit.read_text()
    assert "/home/" not in text and "/data/" not in text, unit.name
  service = (ROOT / "systemd" / "arco-ocean-forecast.service").read_text()
  assert "scripts/forecast.sh --status-url s3://ogs-arco-ocean/status/forecast.json" in service


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="needs systemd-analyze")
def test_units_verify(tmp_path: pathlib.Path):
  # systemd's own check of the units (syntax, settings, the commands they run).
  for unit in UNITS:
    shutil.copy(unit, tmp_path / unit.name)
  result = subprocess.run(
    ["systemd-analyze", "--user", "verify", *(str(tmp_path / unit.name) for unit in UNITS)],
    capture_output=True,
    text=True,
    cwd=tmp_path,
  )
  assert result.returncode == 0, result.stderr
  calendar = subprocess.run(
    ["systemd-analyze", "calendar", "*-*-* 12:00:00 UTC"], capture_output=True, text=True
  )
  assert calendar.returncode == 0 and "12:00:00 UTC" in calendar.stdout


def test_install_links_the_units_and_writes_the_drop_ins(fake: dict[str, str]):
  result = run("install_units.sh", fake, "--keepalive", "--", "--image", "a%b.sif")
  assert result.returncode == 0, result.stderr
  assert "sudo loginctl enable-linger someone" in result.stdout
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  forecast = (unit_dir / "arco-ocean-forecast.service.d" / "local.conf").read_text()
  assert f"WorkingDirectory={ROOT}\n" in forecast
  # % doubled: systemd would read it as a specifier.
  assert 'Environment="FORECAST_OPTIONS=--image a%%b.sif"' in forecast
  keeper = (unit_dir / "arco-ocean-watchdog-keepalive.service.d" / "local.conf").read_text()
  assert f"WorkingDirectory={ROOT}\n" in keeper and "FORECAST_OPTIONS" not in keeper
  made = calls(fake)
  for name in ("arco-ocean-forecast", "arco-ocean-watchdog-keepalive"):
    assert (
      f"systemctl --user link {ROOT}/systemd/{name}.service {ROOT}/systemd/{name}.timer" in made
    )
    assert f"systemctl --user enable --now {name}.timer" in made
  assert made.index("systemctl --user daemon-reload") < made.index(
    "systemctl --user enable --now arco-ocean-forecast.timer"
  )


def test_install_without_keepalive_or_start(fake: dict[str, str]):
  result = run("install_units.sh", fake, "--no-start")
  assert result.returncode == 0, result.stderr
  made = calls(fake)
  assert "systemctl --user enable arco-ocean-forecast.timer" in made
  assert not any("keepalive" in call for call in made)
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  drop_in = (unit_dir / "arco-ocean-forecast.service.d" / "local.conf").read_text()
  assert 'Environment="FORECAST_OPTIONS="' in drop_in


def test_install_lingering_needs_no_advice(fake: dict[str, str]):
  result = run("install_units.sh", fake | {"FAKE_LINGER": "yes"})
  assert result.returncode == 0 and "enable-linger" not in result.stdout


@pytest.mark.parametrize("option", ["a b", 'a"b', "a'b", "a\\b", "$HOME"])
def test_install_refuses_options_systemd_would_split_or_expand(fake: dict[str, str], option):
  result = run("install_units.sh", fake, "--", "--env-file", option)
  assert result.returncode == 1 and "Error: option" in result.stderr
  assert calls(fake) == []


def test_install_options_go_after_the_separator(fake: dict[str, str]):
  result = run("install_units.sh", fake, "--image", "x.sif")
  assert result.returncode == 1 and "go after --" in result.stderr


def test_uninstall_removes_the_links_and_drop_ins(fake: dict[str, str], tmp_path: pathlib.Path):
  assert run("install_units.sh", fake, "--keepalive").returncode == 0
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  # What systemctl --user link would have made.
  (unit_dir / "arco-ocean-forecast.service").symlink_to(
    ROOT / "systemd/arco-ocean-forecast.service"
  )
  (unit_dir / "unrelated.service").write_text("")
  # A drop-in of the user's own (systemctl --user edit) stays.
  (unit_dir / "arco-ocean-forecast.service.d" / "override.conf").write_text("[Service]\n")
  result = run("install_units.sh", fake, "--uninstall")
  assert result.returncode == 0, result.stderr
  assert sorted(path.name for path in unit_dir.iterdir()) == [
    "arco-ocean-forecast.service.d",
    "unrelated.service",
  ]
  assert [path.name for path in (unit_dir / "arco-ocean-forecast.service.d").iterdir()] == [
    "override.conf"
  ]
  made = calls(fake)
  for name in ("arco-ocean-forecast", "arco-ocean-watchdog-keepalive"):
    assert f"systemctl --user disable --now {name}.timer" in made
    # A collection running is stopped too.
    assert f"systemctl --user stop {name}.service" in made


def test_install_from_another_checkout_moves_the_units(fake: dict[str, str], tmp_path):
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  unit_dir.mkdir(parents=True)
  old = tmp_path / "old-checkout" / "arco-ocean-forecast.service"
  old.parent.mkdir()
  old.write_text("")
  (unit_dir / "arco-ocean-forecast.service").symlink_to(old)
  result = run("install_units.sh", fake)
  assert result.returncode == 0, result.stderr
  # The old link is gone (systemctl link, a stand-in here, would make the new one).
  assert not (unit_dir / "arco-ocean-forecast.service").is_symlink()
  made = calls(fake)
  assert made.index("systemctl --user disable arco-ocean-forecast.timer") < made.index(
    f"systemctl --user link {ROOT}/systemd/arco-ocean-forecast.service"
    f" {ROOT}/systemd/arco-ocean-forecast.timer"
  )


def test_install_refuses_to_replace_a_unit_file_of_its_own(fake: dict[str, str]):
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  unit_dir.mkdir(parents=True)
  (unit_dir / "arco-ocean-forecast.timer").write_text("[Timer]\n")
  result = run("install_units.sh", fake)
  assert result.returncode == 1 and "a file of its own" in result.stderr
  assert (unit_dir / "arco-ocean-forecast.timer").read_text() == "[Timer]\n"


def test_install_keepalive_repo(fake: dict[str, str], tmp_path):
  result = run("install_units.sh", fake, "--keepalive", "--keepalive-repo", "someone/arco-ocean")
  assert result.returncode == 0, result.stderr
  unit_dir = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "systemd" / "user"
  keeper = (unit_dir / "arco-ocean-watchdog-keepalive.service.d" / "local.conf").read_text()
  assert 'Environment="KEEPALIVE_OPTIONS=--repo someone/arco-ocean"' in keeper
  bad = run("install_units.sh", fake, "--keepalive", "--keepalive-repo", "a b")
  assert bad.returncode == 1 and "takes OWNER/REPO" in bad.stderr
  # Installed again without --keepalive: the keepalive stays, and the installer says so.
  link = unit_dir / "arco-ocean-watchdog-keepalive.service"
  link.symlink_to(tmp_path / "elsewhere.service")
  again = run("install_units.sh", fake)
  assert again.returncode == 0 and "The keepalive installed before stays" in again.stdout


@pytest.fixture
def token(fake: dict[str, str]) -> pathlib.Path:
  path = pathlib.Path(fake["XDG_CONFIG_HOME"]) / "arco-ocean" / "github-token"
  path.parent.mkdir(parents=True)
  path.write_text("not-a-real-token")
  path.chmod(0o600)
  return path


@pytest.mark.parametrize(
  ("state", "enabled", "said"),
  [
    ("active", True, "active (enabled again"),
    ("disabled_inactivity", True, "was disabled for inactivity, enabled again"),
    ("disabled_manually", False, "disabled by hand, left disabled"),
  ],
)
def test_keepalive_enables_unless_disabled_by_hand(
  fake: dict[str, str], token: pathlib.Path, state: str, enabled: bool, said: str
):
  result = run("keep_watchdog_enabled.sh", fake | {"FAKE_STATE": state})
  assert result.returncode == 0, result.stderr
  assert said in result.stdout
  endpoint = "repos/inogs/arco-ocean/actions/workflows/forecast-watchdog.yml"
  made = calls(fake)
  assert made[0] == f"gh api {endpoint} --jq .state"
  assert (f"gh api --method PUT {endpoint}/enable" in made) is enabled
  # The token reaches gh through its environment, never its arguments or the output.
  assert all("not-a-real-token" not in call for call in made)
  assert "not-a-real-token" not in result.stdout + result.stderr
  assert (
    pathlib.Path(fake["CALLS"] + ".env").read_text().splitlines()[0] == "token not-a-real-token"
  )


def test_keepalive_fails_on_another_state(fake: dict[str, str], token: pathlib.Path):
  result = run("keep_watchdog_enabled.sh", fake | {"FAKE_STATE": "deleted"}, "--repo", "o/r")
  assert result.returncode == 1 and "o/r forecast-watchdog.yml is 'deleted'" in result.stderr


def test_keepalive_needs_a_private_token_file(fake: dict[str, str], token: pathlib.Path):
  token.chmod(0o644)
  result = run("keep_watchdog_enabled.sh", fake | {"FAKE_STATE": "active"})
  assert result.returncode == 1 and "readable by others" in result.stderr
  missing = run("keep_watchdog_enabled.sh", fake, "--token-file", str(token) + ".missing")
  assert missing.returncode == 1 and "no token file" in missing.stderr
  # Empty, gh would use its own login instead.
  token.chmod(0o600)
  token.write_text("\n")
  empty = run("keep_watchdog_enabled.sh", fake | {"FAKE_STATE": "active"})
  assert empty.returncode == 1 and "is empty" in empty.stderr
  assert calls(fake) == []


def test_keepalive_follows_a_linked_token_file(fake: dict[str, str], token: pathlib.Path):
  link = token.with_name("linked-token")
  link.symlink_to(token)
  result = run(
    "keep_watchdog_enabled.sh", fake | {"FAKE_STATE": "active"}, "--token-file", str(link)
  )
  assert result.returncode == 0, result.stderr


def test_scripts_are_executable():
  for name in ("install_units.sh", "keep_watchdog_enabled.sh"):
    assert os.access(ROOT / "scripts" / name, os.X_OK), name
