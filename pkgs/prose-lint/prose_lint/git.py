from __future__ import annotations

import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

TIMEOUT_SECONDS = 10.0


class Git(Protocol):
    """The git questions that prose-lint asks about its working directory."""

    def root(self) -> Path | None: ...

    def common_directory(self) -> Path | None: ...

    def remote_urls(self) -> tuple[str, ...]: ...

    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int: ...

    def changed_paths(self) -> tuple[Path, ...]: ...

    def untracked_paths(self) -> tuple[Path, ...]: ...

    def diff_against_head(self, path: Path) -> str: ...

    def diff_staged(self, path: Path) -> str: ...


@dataclass(frozen=True)
class SubprocessGit:
    cwd: Path
    program: str = "git"

    def root(self) -> Path | None:
        output = self._run(["rev-parse", "--show-toplevel"])

        return None if output is None else Path(output.strip())

    def common_directory(self) -> Path | None:
        output = self._run(["rev-parse", "--path-format=absolute", "--git-common-dir"])

        return None if output is None else Path(output.strip())

    def remote_urls(self) -> tuple[str, ...]:
        output = self._run(["remote", "--verbose"])
        if output is None:
            return ()

        urls = {
            line.split()[1] for line in output.splitlines() if len(line.split()) >= 2
        }

        return tuple(sorted(urls))

    def changed_paths(self) -> tuple[Path, ...]:
        """The tracked files the working tree differs from HEAD in."""
        return self._paths(["diff", "--name-only", "--no-relative", "HEAD"])

    def untracked_paths(self) -> tuple[Path, ...]:
        """The files git does not track and has not been told to ignore."""
        return self._paths(
            ["ls-files", "--others", "--exclude-standard", "--full-name"]
        )

    def diff_against_head(self, path: Path) -> str:
        """One file's working-tree diff against HEAD, with no context lines."""
        return self._run(["diff", "--unified=0", "HEAD", "--", str(path)]) or ""

    def diff_staged(self, path: Path) -> str:
        """One file's index diff against HEAD, with no context lines."""
        return (
            self._run(["diff", "--cached", "--unified=0", "HEAD", "--", str(path)])
            or ""
        )

    def _paths(self, arguments: list[str]) -> tuple[Path, ...]:
        output = self._run(arguments)
        if output is None:
            return ()

        return tuple(Path(line) for line in output.splitlines() if line)

    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int:
        """How many tracked lines contain a whole word matching `pattern`."""
        output = self._run(
            [
                "grep",
                "--count",
                "--ignore-case",
                "--word-regexp",
                "--extended-regexp",
                pattern,
                "--",
                *pathspec,
            ]
        )

        if output is None:
            return 0

        total = 0
        for line in output.splitlines():
            _, _, count = line.rpartition(":")
            if count.isdigit():
                total += int(count)

        return total

    def _run(self, arguments: list[str]) -> str | None:
        try:
            completed = subprocess.run(
                [self.program, *arguments],
                cwd=self.cwd,
                capture_output=True,
                text=True,
                check=False,
                timeout=TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None

        if completed.returncode != 0:
            return None

        return completed.stdout
