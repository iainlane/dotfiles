"""Constrained filesystem reads shared by MCP evidence providers."""

import os
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from ..errors import ConformanceError
from .models import TextPage


@dataclass(eq=True)
class McpPathOutsideRootError(ConformanceError):
    root: Path
    requested: str

    def __str__(self) -> str:
        return f"{self.requested!r} is outside the permitted root {self.root}"


@dataclass(eq=True)
class McpDocumentReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"MCP could not read {self.source}: {self.cause}"


def read_text(path: Path) -> str:
    """Read a UTF-8 evidence document and retain its typed failure cause."""

    try:
        return path.read_text()
    except OSError as error:
        raise McpDocumentReadError(path, error) from error


def read_page(
    path: Path,
    offset: int,
    limit: int,
    *,
    display_path: str | None = None,
) -> TextPage:
    """Read a bounded character range and identify the next range, when present."""

    text = read_text(path)
    selected = text[offset : offset + limit]
    next_offset = offset + len(selected)
    if next_offset >= len(text):
        next_offset = None
    return TextPage(
        path=display_path or path.name,
        offset=offset,
        next_offset=next_offset,
        text=selected,
    )


def relative_path(root: Path, value: str) -> PurePosixPath:
    """Parse a path that remains relative to an evidence capability root."""

    path = PurePosixPath(value or ".")
    if path.is_absolute() or ".." in path.parts:
        raise McpPathOutsideRootError(root, value)
    return path


def logical_child(root: Path, value: str) -> Path:
    """Address a declared prompt file while allowing immutable Nix symlinks."""

    return root.joinpath(*relative_path(root, value).parts)


def resolved_child(root: Path, relative: PurePosixPath) -> Path:
    """Resolve a workspace path while keeping it inside the workspace root."""

    resolved_root = root.resolve()
    candidate = resolved_root.joinpath(*relative.parts).resolve()
    try:
        candidate.relative_to(resolved_root)
    except ValueError as error:
        raise McpPathOutsideRootError(root, str(relative)) from error
    return candidate


def list_files(
    root: Path, display_prefix: PurePosixPath, limit: int
) -> tuple[tuple[str, ...], bool]:
    """List regular files beneath a capability root with a deterministic bound."""

    if root.is_file():
        return (str(display_prefix),), False
    files: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = display_prefix / path.relative_to(root).as_posix()
        files.append(str(relative))
        if len(files) == limit:
            return tuple(files), True
    return tuple(files), False


def list_workspace_files(
    root: Path,
    display_prefix: PurePosixPath,
    offset: int,
    limit: int,
) -> tuple[tuple[str, ...], int | None]:
    """Page repository files without traversing generated or control trees."""

    ignored_directories = {".claude", ".direnv", ".git", "node_modules", "target"}
    selected: list[str] = []
    seen = 0
    for directory, directories, files in os.walk(root, followlinks=False):
        current = Path(directory)
        directories[:] = sorted(
            name
            for name in directories
            if name not in ignored_directories and not (current / name).is_symlink()
        )
        for name in sorted(files):
            path = current / name
            if path.is_symlink():
                continue
            if seen < offset:
                seen += 1
                continue
            if len(selected) == limit:
                return tuple(selected), offset + len(selected)
            relative = display_prefix / path.relative_to(root).as_posix()
            selected.append(str(relative))
            seen += 1
    return tuple(selected), None
