# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""Every recipe loads with the models of the pinned arco-make, as its commands read it: unknown
keys, unknown steps and wrong arguments fail here, not at the start of a download (no data are
read)."""

import pathlib

import pytest
from arcomake.cli_utils import read_configs
from arcomake.climatology import ClimatologyConfig
from arcomake.download import DownloadConfig
from arcomake.validate import ValidateConfig

CONFIGS = pathlib.Path(__file__).parent.parent / "configs"
# The model of each recipe folder: the command that reads its recipes.
SCHEMAS = {"download": DownloadConfig, "climatology": ClimatologyConfig, "validate": ValidateConfig}
RECIPES = sorted(CONFIGS.rglob("*.toml"))


def test_every_folder_has_a_model():
  """A recipe in a folder without a model would go unchecked."""
  assert RECIPES
  assert {path.parent.name for path in RECIPES} <= set(SCHEMAS)


@pytest.mark.parametrize("path", RECIPES, ids=lambda path: str(path.relative_to(CONFIGS)))
def test_the_recipe_loads(path: pathlib.Path):
  read_configs(str(path), schema=SCHEMAS[path.parent.name])
