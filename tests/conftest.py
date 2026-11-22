# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""Tests marked `live` read the real sources: skipped unless pytest is given `--live`."""

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
  parser.addoption("--live", action="store_true", help="run the tests reading the real sources")


def pytest_configure(config: pytest.Config) -> None:
  config.addinivalue_line("markers", "live: reads the real sources (needs --live and credentials)")


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
  if config.getoption("--live"):
    return
  skip = pytest.mark.skip(reason="reads the real sources: run with --live")
  for item in items:
    if "live" in item.keywords:
      item.add_marker(skip)
