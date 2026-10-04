from __future__ import annotations

import re
from collections.abc import Sequence
from pathlib import Path

from pygments.lexers.php import PhpLexer
from pygments.token import Comment, String

_COMMENT_LINE = re.compile(r"^\s*#(?!!)\s?(?P<text>.*)$")
_BLOCK_LINE = re.compile(r"^\s*\*(?: |$)")


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


def php_comments(source: str) -> str:
    """PHP comments as Markdown, with the source's line numbers.

    The lexer distinguishes comments from strings, heredocs and HTML outside
    PHP tags. Blank lines replace code, as they do for hash comments.
    """
    lines = [""] * len(source.splitlines())
    first_line = 0
    previous_position = 0

    for position, token, text in PhpLexer().get_tokens_unprocessed(source):
        first_line += source[previous_position:position].count("\n")
        previous_position = position
        block_comment = token in Comment.Multiline or token in String.Doc

        if token in Comment.Single:
            body = text[2:] if text.startswith("//") else text[1:]
        elif block_comment:
            body = text[2:-2]
        else:
            continue

        for offset, line in enumerate(body.splitlines()):
            content = _BLOCK_LINE.sub("", line) if block_comment else line
            content = content.removeprefix(" ").rstrip()
            index = first_line + offset
            lines[index] = " ".join(part for part in (lines[index], content) if part)

    return "".join(f"{line}\n" for line in lines)


# Every mirror file is given this extension. One scope glob covers all the
# extensions that prose-lint extracts comments from, so a mirror named for any
# one of them selects the rules of the source file.
MIRROR_SUFFIX = ".nix"


def mirror_pairs(
    directory: Path, paths: Sequence[Path]
) -> tuple[tuple[Path, Path], ...]:
    """A file under `directory` for each path's comments, paired with that path.

    The names are numbered and padded to a common width, so their name order is
    the order of `paths`.
    """
    width = len(str(max(len(paths) - 1, 0)))

    return tuple(
        (directory / f"{index:0{width}d}{MIRROR_SUFFIX}", path)
        for index, path in enumerate(paths)
    )
