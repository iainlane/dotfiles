from __future__ import annotations

import re

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
