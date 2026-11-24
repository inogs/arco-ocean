# SPDX-FileCopyrightText: 2026 Stefano Campanella
# SPDX-License-Identifier: MIT
"""The examples of `docs/coarsen-ocean-datasets.md` are doctests.

Code blocks fenced as ```pycon run offline, on synthetic data; blocks fenced as ```pycon live
read the real sources (GLORYS's mask and depth, its empty deepest level, the footnote's premise,
on regional boxes) and run with `--live`, given Copernicus Marine credentials (environment,
`~/.arcomakerc` or the toolbox's file). The blocks of each kind run in order, sharing their names;
failures name the line of the notes.
"""

import doctest
import pathlib
import re

import pytest

NOTES = pathlib.Path(__file__).parents[1] / "docs" / "coarsen-ocean-datasets.md"
FENCE = re.compile(r"^```pycon( live)?\n(.*?)^```$", re.MULTILINE | re.DOTALL)
FLAGS = doctest.ELLIPSIS | doctest.NORMALIZE_WHITESPACE


def examples(live: bool) -> str:
  """The notes' blocks of one kind, at their own line numbers (everything else blanked)."""
  text = NOTES.read_text()
  lines = [""] * (text.count("\n") + 1)
  for match in FENCE.finditer(text):
    if bool(match.group(1)) != live:
      continue
    first = text.count("\n", 0, match.start(2))
    for offset, line in enumerate(match.group(2).splitlines()):
      lines[first + offset] = line
  return "\n".join(lines)


def run_examples(live: bool) -> None:
  source = examples(live)
  assert ">>>" in source, "no examples of this kind in the notes"
  test = doctest.DocTestParser().get_doctest(source, {}, NOTES.name, str(NOTES), 0)
  report: list[str] = []
  runner = doctest.DocTestRunner(optionflags=FLAGS)
  runner.run(test, out=report.append)
  assert runner.failures == 0, "".join(report)


def test_offline_examples_of_the_notes():
  run_examples(live=False)


@pytest.mark.live
def test_live_examples_of_the_notes():
  from arcomake import settings

  settings.load()
  run_examples(live=True)
