from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from prose_lint.levels import Level
from prose_lint.report import Finding

_SEVERITIES = {
    "error": Level.error,
    "warning": Level.warning,
    "suggestion": Level.suggestion,
}


TIMEOUT_SECONDS = 20.0


class ValeMissing(Exception):
    """Vale is not on PATH and PROSE_LINT_VALE does not point at it."""


class ValeFailed(Exception):
    """Vale exited without a result, or did not exit in time."""


@dataclass(frozen=True)
class ValeInvocation:
    config: Path
    paths: tuple[Path, ...] = ()
    stdin_text: str | None = None
    extension: str | None = None
    display_path: str | None = None
    path_hint: str | None = None


class Vale(Protocol):
    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]: ...


@dataclass(frozen=True)
class SubprocessVale:
    """Runs the vale binary.

    The binary is located when `lint` is first called, not when this object
    is built, so a hook that returns before it lints anything succeeds even
    where vale is absent.
    """

    cwd: Path
    program: str | None = None
    timeout: float = TIMEOUT_SECONDS

    def arguments(self, invocation: ValeInvocation) -> list[str]:
        """The vale command line for one invocation.

        Vale reads standard input when it is given no file to read, so an
        invocation with text to lint passes no paths at all.
        """
        arguments = [
            self.program or _locate(),
            "--no-global",
            f"--config={invocation.config}",
            "--output=JSON",
        ]

        if invocation.extension is not None:
            arguments.append(f"--ext={invocation.extension}")

        if invocation.path_hint is not None:
            arguments.append(f"--path={invocation.path_hint}")

        if invocation.stdin_text is None:
            arguments.extend(str(path) for path in invocation.paths)

        return arguments

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        try:
            completed = subprocess.run(
                self.arguments(invocation),
                cwd=self.cwd,
                input=invocation.stdin_text,
                capture_output=True,
                text=True,
                check=False,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired as expired:
            raise ValeFailed(
                f"vale did not finish within {self.timeout:g} seconds"
            ) from expired

        return _parse(
            completed.stdout,
            completed.stderr,
            invocation.display_path,
            returncode=completed.returncode,
        )


def _locate() -> str:
    configured = os.environ.get("PROSE_LINT_VALE")
    if configured:
        return configured

    found = shutil.which("vale")
    if found is None:
        raise ValeMissing(
            "prose-lint needs vale on PATH or the path to it in PROSE_LINT_VALE."
        )

    return found


def _parse(
    stdout: str,
    stderr: str,
    display_path: str | None,
    *,
    returncode: int = 0,
) -> tuple[Finding, ...]:
    """The findings in vale's JSON output.

    Vale exits non-zero whenever it reports an alert, so the exit status alone
    does not distinguish a failure from a finding. Blank output together with
    a non-zero status does.
    """
    if returncode != 0 and not stdout.strip():
        raise ValeFailed(f"vale exited {returncode}: {_error_text(stderr)}")

    try:
        document = json.loads(stdout or "{}")
    except json.JSONDecodeError as error:
        raise ValeFailed(f"vale did not return JSON: {stderr.strip()}") from error

    if isinstance(document, dict) and "Code" in document:
        raise ValeFailed(f"vale reported an error: {document.get('Text', stdout)}")

    findings: list[Finding] = []

    for path, alerts in sorted(document.items()):
        for alert in alerts:
            severity = _SEVERITIES.get(alert["Severity"])
            if severity is None:
                continue

            findings.append(
                Finding(
                    path=display_path or path,
                    line=alert["Line"],
                    column=alert["Span"][0],
                    rule=alert["Check"],
                    message=alert["Message"],
                    severity=severity,
                )
            )

    return tuple(findings)


def _error_text(stderr: str) -> str:
    """What vale said went wrong, on one line.

    Under `--output=JSON` an error is reported as a JSON document with the
    message in `Text`, so a finding built from it reads as one line.
    """
    try:
        document = json.loads(stderr)
    except json.JSONDecodeError:
        return stderr.strip()

    if isinstance(document, dict) and isinstance(document.get("Text"), str):
        return document["Text"]

    return stderr.strip()
