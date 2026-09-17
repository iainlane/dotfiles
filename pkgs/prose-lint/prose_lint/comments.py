from __future__ import annotations

import re
from collections.abc import Sequence
from pathlib import Path

_COMMENT_LINE = re.compile(r"^\s*#(?!!)\s?(?P<text>.*)$")


def hash_comments(source: str) -> str:
    """The `#` comments of `source`, one output line per input line.

    Every line that is not a comment becomes blank, so a line number in the
    result is a line number in the source, and runs of comment lines read as
    Markdown paragraphs. A shebang is not a comment.
    """
    lines = []

    for line in source.splitlines():
        match = _COMMENT_LINE.match(line)
        lines.append(match.group("text") if match else "")

    return "".join(f"{line}\n" for line in lines)


# Every mirror file is given this extension. The scope glob for code covers
# every extension whose comments prose-lint extracts, so the rules Vale runs
# on a mirror file are the rules it runs on the source file.
MIRROR_SUFFIX = ".nix"


def mirror_pairs(
    directory: Path, paths: Sequence[Path]
) -> tuple[tuple[Path, Path], ...]:
    """A file under `directory` for each path's comments, paired with that path.

    The names are numbered and padded to a common width, so reading them in
    name order reads the paths in the order they were given.
    """
    width = len(str(max(len(paths) - 1, 0)))

    return tuple(
        (directory / f"{index:0{width}d}{MIRROR_SUFFIX}", path)
        for index, path in enumerate(paths)
    )
