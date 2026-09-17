import re
from pathlib import Path

import pytest

from prose_lint.levels import Level
from prose_lint.report import Finding
from prose_lint.vale import (
    SubprocessVale,
    ValeFailed,
    ValeInvocation,
    ValeMissing,
    _parse,
)

RUNNER = SubprocessVale(cwd=Path("/work"), program="/store/bin/vale")
CONFIG = Path("/tmp/vale.ini")


def test_files_are_passed_as_arguments() -> None:
    invocation = ValeInvocation(config=CONFIG, paths=(Path("README.md"),))

    assert RUNNER.arguments(invocation) == [
        "/store/bin/vale",
        "--no-global",
        "--config=/tmp/vale.ini",
        "--output=JSON",
        "README.md",
    ]


def test_text_is_passed_on_standard_input_with_no_file_argument() -> None:
    invocation = ValeInvocation(
        config=CONFIG,
        stdin_text="fix(db): index foo by quux\n",
        extension=".txt",
    )

    assert RUNNER.arguments(invocation) == [
        "/store/bin/vale",
        "--no-global",
        "--config=/tmp/vale.ini",
        "--output=JSON",
        "--ext=.txt",
    ]


def test_a_path_hint_is_passed_for_text_on_standard_input() -> None:
    invocation = ValeInvocation(
        config=CONFIG,
        stdin_text="# A comment.\n",
        extension=".md",
        path_hint="features/x.nix",
    )

    assert RUNNER.arguments(invocation) == [
        "/store/bin/vale",
        "--no-global",
        "--config=/tmp/vale.ini",
        "--output=JSON",
        "--ext=.md",
        "--path=features/x.nix",
    ]


def test_the_display_path_replaces_the_path_vale_reports() -> None:
    stdout = """
    {"stdin.txt": [{
      "Check": "Prose.Trailers",
      "Line": 3,
      "Span": [1, 15],
      "Message": "'Co-Authored-By:' is a commit trailer this project does not use.",
      "Severity": "error",
      "Match": "Co-Authored-By:"
    }]}
    """

    assert _parse(stdout, "", "commit message") == (
        Finding(
            path="commit message",
            line=3,
            column=1,
            rule="Prose.Trailers",
            message="'Co-Authored-By:' is a commit trailer this project does not use.",
            severity=Level.error,
        ),
    )


def test_blank_output_with_a_failure_status_is_a_failure() -> None:
    with pytest.raises(ValeFailed, match="vale exited 1: boom"):
        _parse("", "boom", None, returncode=1)


def test_a_json_error_report_is_read_down_to_its_message() -> None:
    stderr = """
    {
      "Line": 1,
      "Path": "note.md",
      "Text": "yaml: line 5: could not find expected ':'",
      "Code": "E201",
      "Span": 1
    }
    """

    with pytest.raises(
        ValeFailed,
        match=re.escape("vale exited 2: yaml: line 5: could not find expected ':'"),
    ):
        _parse("", stderr, None, returncode=2)


def test_blank_output_with_a_success_status_is_no_findings() -> None:
    assert _parse("", "", None, returncode=0) == ()


def test_a_missing_vale_is_reported_only_when_linting(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("PROSE_LINT_VALE", raising=False)
    monkeypatch.setenv("PATH", str(tmp_path))
    runner = SubprocessVale(cwd=tmp_path)

    with pytest.raises(ValeMissing):
        runner.lint(ValeInvocation(config=CONFIG, paths=(Path("README.md"),)))


def test_a_vale_that_does_not_finish_is_a_failure(tmp_path: Path) -> None:
    script = tmp_path / "vale"
    script.write_text("#!/bin/sh\nsleep 5\n")
    script.chmod(0o755)
    runner = SubprocessVale(cwd=tmp_path, program=str(script), timeout=0.2)

    with pytest.raises(ValeFailed, match="did not finish within 0.2 seconds"):
        runner.lint(ValeInvocation(config=CONFIG, paths=(Path("README.md"),)))


def test_the_environment_variable_names_the_binary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PROSE_LINT_VALE", "/elsewhere/vale")
    invocation = ValeInvocation(config=CONFIG, paths=(Path("README.md"),))

    assert (
        SubprocessVale(cwd=Path("/work")).arguments(invocation)[0] == "/elsewhere/vale"
    )
