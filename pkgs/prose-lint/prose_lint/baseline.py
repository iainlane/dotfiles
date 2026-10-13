from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

# A baseline older than this belongs to a session that has almost certainly
# ended, so recording a new baseline deletes it.
RETENTION_SECONDS = 30 * 24 * 60 * 60


@dataclass(frozen=True)
class Baseline:
    """The files that differed from HEAD before a session changed anything.

    `digests` maps each file's path, relative to the repository root, to the
    SHA-256 digest of its contents at that point. A file whose digest is still
    the same has not been changed by the session.
    """

    digests: Mapping[str, str]

    @classmethod
    def capture(cls, root: Path, paths: Iterable[Path]) -> Baseline:
        digests = {
            path.as_posix(): digest
            for path in paths
            if (digest := file_digest(root / path)) is not None
        }

        return cls(digests=digests)

    @classmethod
    def read(cls, path: Path) -> Baseline | None:
        """The baseline at `path`, or None when the session has not recorded one."""
        try:
            document = json.loads(path.read_text())
        except FileNotFoundError:
            return None

        return cls(digests=dict(document["digests"]))

    def unchanged(self, root: Path, path: Path) -> bool:
        """Whether `path` has the contents that it had in the baseline."""
        recorded = self.digests.get(path.as_posix())

        return recorded is not None and recorded == file_digest(root / path)

    def write_once(self, path: Path) -> None:
        """Write the baseline to `path` unless a baseline is already there.

        Hooks for parallel tool calls can race to record the same baseline.
        `os.link` fails when `path` exists, so the first complete baseline is
        kept and a later one cannot replace it.
        """
        path.parent.mkdir(parents=True, exist_ok=True)

        descriptor, scratch = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
        try:
            with os.fdopen(descriptor, "w") as file:
                json.dump({"digests": dict(sorted(self.digests.items()))}, file)

            os.link(scratch, path)
        except FileExistsError:
            pass
        finally:
            os.unlink(scratch)


def file_digest(path: Path) -> str | None:
    """The SHA-256 digest of a file's contents, or None when it cannot be read."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def prune(directory: Path, now: float | None = None) -> None:
    """Delete the baselines under `directory` that are past their retention."""
    cutoff = (time.time() if now is None else now) - RETENTION_SECONDS

    for baseline in directory.glob("*.json"):
        try:
            expired = baseline.stat().st_mtime < cutoff
        except FileNotFoundError:
            continue

        if expired:
            baseline.unlink(missing_ok=True)
