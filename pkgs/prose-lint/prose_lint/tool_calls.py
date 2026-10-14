from __future__ import annotations

import re
from collections.abc import Mapping
from pathlib import Path

# Claude Code's file-editing tools, which give the file's path in `file_path`.
_FILE_PATH_TOOLS = frozenset({"Edit", "Write", "MultiEdit"})

# Codex sends an `apply_patch` call with the patch text in `command`.
_PATCH_TOOL = "apply_patch"

_PATCH_HEADER = re.compile(
    r"^\*\*\* (?P<action>Add File|Update File|Delete File|Move to): (?P<path>.+)$"
)


def edited_paths(
    tool_name: object, tool_input: Mapping[str, object], cwd: Path
) -> tuple[Path, ...]:
    """The files that an edit tool call writes, resolved against `cwd`.

    The result is empty for any other tool and for an input of the wrong
    shape.
    """
    if tool_name in _FILE_PATH_TOOLS:
        file_path = tool_input.get("file_path")
        if not isinstance(file_path, str):
            return ()

        return (cwd / file_path,)

    if tool_name != _PATCH_TOOL:
        return ()

    patch = tool_input.get("command")
    if not isinstance(patch, str):
        return ()

    return tuple(cwd / path for path in _patched_paths(patch))


def _patched_paths(patch: str) -> tuple[str, ...]:
    """The files that a Codex patch leaves in the working tree, in patch order.

    A deleted file is left out. A file moved with `*** Move to:` is listed
    under its new path.
    """
    paths: list[str] = []

    for line in patch.splitlines():
        header = _PATCH_HEADER.match(line)
        if header is None:
            continue

        action, path = header.group("action"), header.group("path").strip()

        if action == "Delete File":
            continue

        if action == "Move to" and paths:
            paths[-1] = path
            continue

        paths.append(path)

    return tuple(paths)
