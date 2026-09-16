from __future__ import annotations

import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

TIMEOUT_SECONDS = 10.0


class Git(Protocol):
    """The git questions prose-lint asks about the directory it runs in."""

    def root(self) -> Path | None: ...

    def common_directory(self) -> Path | None: ...

    def remote_urls(self) -> tuple[str, ...]: ...

    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int: ...


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
