import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

from prose_lint.cli import main
from prose_lint.report import ADVICE
from tests.conftest import git


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


def test_the_stop_hook_reports_nothing_while_it_is_already_active(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("PROSE_LINT_VALE", str(tmp_path / "absent"))
    payload = {"stop_hook_active": True, "cwd": str(tmp_path)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    status = main(["hook", "stop"])

    assert (status, capsys.readouterr().out) == (0, "")


EM_DASH = "—"

FAKE_VALE = """\
import json
import sys

path = [argument for argument in sys.argv[1:] if not argument.startswith("-")][0]
alerts = [
    {
        "Line": number,
        "Span": [1, 1],
        "Check": "Prose.EmDash",
        "Message": "An em dash.",
        "Severity": "error",
    }
    for number, line in enumerate(open(path).read().splitlines(), start=1)
    if chr(0x2014) in line
]

print(json.dumps({path: alerts} if alerts else {}))
"""


def fake_vale(directory: Path) -> Path:
    """A vale that reports an error on every line containing an em dash."""
    script = directory / "vale"
    script.write_text(f"#!{sys.executable}\n{FAKE_VALE}")
    script.chmod(0o755)

    return script


def test_fake_vale_runs_without_python_on_path(tmp_path: Path) -> None:
    note = tmp_path / "note.md"
    note.write_text("A clean sentence.\n")

    result = subprocess.run(
        [str(fake_vale(tmp_path)), str(note)],
        check=False,
        capture_output=True,
        text=True,
        env={"PATH": str(tmp_path)},
    )

    assert (result.returncode, result.stdout, result.stderr) == (0, "{}\n", "")


@pytest.mark.parametrize(
    ("added", "expected"),
    [
        ("A clean sentence.\n", (0, "")),
        (
            f"A second sentence {EM_DASH} with an em dash.\n",
            (1, f"notes.md:2:1 Prose.EmDash: An em dash.\n\n{ADVICE}\n"),
        ),
    ],
)
def test_the_staged_check_reports_only_the_lines_the_index_adds(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    added: str,
    expected: tuple[int, str],
) -> None:
    committed = f"A sentence {EM_DASH} with an em dash.\n"
    notes = repository / "notes.md"
    notes.write_text(committed)
    git(repository, "add", "notes.md")
    git(repository, "commit", "--message", "write a line with an em dash")
    notes.write_text(committed + added)
    git(repository, "add", "notes.md")
    monkeypatch.setenv("PROSE_LINT_VALE", str(fake_vale(repository)))
    monkeypatch.chdir(repository)

    status = main(["check", "--staged", "notes.md"])

    assert (status, capsys.readouterr().out) == expected
