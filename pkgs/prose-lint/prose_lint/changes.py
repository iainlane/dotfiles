from __future__ import annotations

import re
from pathlib import Path

_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(?P<start>\d+)(?:,(?P<count>\d+))? @@")


def added_lines(diff: str) -> frozenset[int]:
    """The line numbers on the new side of a unified diff.

    `git diff -U0` writes no context lines, so a hunk header covers only the
    added and rewritten lines. A hunk that only deletes has a count of zero,
    which makes its range empty.
    """
    lines: set[int] = set()

    for line in diff.splitlines():
        match = _HUNK.match(line)
        if match is None:
            continue

        start = int(match.group("start"))
        count = 1 if match.group("count") is None else int(match.group("count"))
        lines.update(range(start, start + count))

    return frozenset(lines)


def every_line(path: Path) -> frozenset[int]:
    """Every line number in a file. An untracked file counts as added in full."""
    try:
        text = path.read_text()
    except OSError:
        return frozenset()

    return frozenset(range(1, len(text.splitlines()) + 1))
