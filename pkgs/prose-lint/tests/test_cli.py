import io
from pathlib import Path

import pytest

from prose_lint.cli import main


def test_a_broken_vale_is_reported_against_the_file_not_as_a_traceback(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    broken = tmp_path / "vale"
    broken.write_text("#!/bin/sh\necho boom >&2\nexit 1\n")
    broken.chmod(0o755)
    (tmp_path / "note.md").write_text("A note.\n")
    monkeypatch.setenv("PROSE_LINT_VALE", str(broken))
    monkeypatch.chdir(tmp_path)

    status = main(["check", "note.md"])
    captured = capsys.readouterr()

    assert (status, captured.err, captured.out.splitlines()[0]) == (
        1,
        "",
        "note.md:1:1 prose-lint: vale exited 1: boom",
    )


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        (
            "not json",
            '{"systemMessage": "prose-lint did not run: Expecting value: line 1 column 1 (char 0)"}\n',
        ),
        ('{"tool_name": "Read", "tool_input": {"file_path": "/x"}}', ""),
        ('{"tool_name": "Bash", "tool_input": {"command": "ls"}}', ""),
    ],
)
def test_the_hook_answers_every_payload_with_valid_output_and_status_zero(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    payload: str,
    expected: str,
) -> None:
    monkeypatch.setenv("PROSE_LINT_VALE", str(tmp_path / "absent"))
    monkeypatch.setattr("sys.stdin", io.StringIO(payload))
    event = "pre-tool-use" if "Bash" in payload else "post-tool-use"

    status = main(["hook", event])

    assert (status, capsys.readouterr().out) == (0, expected)
