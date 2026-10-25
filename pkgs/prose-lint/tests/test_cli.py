import io
import json
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

import pytest

from prose_lint.cli import main
from prose_lint.levels import Level
from prose_lint.overrides import Override, read_overrides
from prose_lint.report import ADVICE
from prose_lint.rules import RuleCatalogue
from tests.conftest import git

SOURCE = Path(__file__).resolve().parent.parent


def test_allow_records_and_reports_an_ordered_file_scope(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(repository)
    arguments = [
        "allow",
        "EmDash",
        "--level",
        "NO",
        "--file",
        "docs/**",
        "--file",
        "!docs/generated/**",
        "--because",
        "notes.md permits em dashes",
    ]

    assert main(arguments) == 0
    allowed = capsys.readouterr()
    assert main(["overrides"]) == 0
    listed = capsys.readouterr()
    rendered = (
        "prose-lint runs EmDash at NO for ['docs/**', '!docs/generated/**']: "
        "notes.md permits em dashes\n"
    )

    assert (allowed.out, allowed.err, listed.out, listed.err) == (
        rendered,
        "",
        rendered,
        "",
    )
    assert read_overrides(
        repository / ".git/info/prose-lint.toml",
        RuleCatalogue.load(SOURCE / "tiers.toml"),
    ) == (
        Override(
            "EmDash",
            Level.off,
            "notes.md permits em dashes",
            files=("docs/**", "!docs/generated/**"),
        ),
    )

    assert main(["disallow", "EmDash"]) == 0
    assert main(["overrides"]) == 0
    assert capsys.readouterr().out == (
        "EmDash runs at its configured level again.\nNo rule is lowered here.\n"
    )


@pytest.mark.parametrize("files", ["[]", '["invalid\\\\"]'])
def test_invalid_stored_scopes_produce_a_cli_error(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    files: str,
) -> None:
    monkeypatch.chdir(repository)
    path = repository / ".git/info/prose-lint.toml"
    path.parent.mkdir(exist_ok=True)
    path.write_text(
        f'[overrides.EmDash]\nlevel = "NO"\nbecause = "notes.md"\nfiles = {files}\n'
    )

    assert main(["overrides"]) == 2
    captured = capsys.readouterr()
    assert (captured.out, captured.err.startswith("prose-lint: ")) == ("", True)


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

paths = [argument for argument in sys.argv[1:] if not argument.startswith("-")]
alerts = {
    path: [
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
    for path in paths
}

print(json.dumps({path: found for path, found in alerts.items() if found}))
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


def answer_hook(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    event: str,
    payload: Mapping[str, object],
) -> str:
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    assert main(["hook", event]) == 0

    return capsys.readouterr().out


def test_the_stop_hook_reports_only_the_files_changed_after_the_first_edit(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("PROSE_LINT_VALE", str(fake_vale(repository)))
    (repository / "older.md").write_text(f"Written before {EM_DASH} the session.\n")
    session = {"session_id": "session", "cwd": str(repository)}
    edit = {"tool_name": "Edit", "tool_input": {"file_path": "fresh.md"}}

    before = answer_hook(monkeypatch, capsys, "pre-tool-use", {**session, **edit})
    subprocess.run(
        ["sh", "-c", f"printf 'Written by a shell {EM_DASH} command.\\n' > fresh.md"],
        cwd=repository,
        check=True,
    )
    stop = answer_hook(monkeypatch, capsys, "stop", session)

    assert (before, json.loads(stop)) == (
        "",
        {
            "decision": "block",
            "reason": (
                f"errors\n{repository / 'fresh.md'}:1:1 Prose.EmDash: An em dash."
                f"\n\n{ADVICE}"
            ),
        },
    )


def test_a_codex_patch_has_the_files_it_writes_linted(
    repository: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("PROSE_LINT_VALE", str(fake_vale(repository)))
    (repository / "fresh.md").write_text(f"Written by {EM_DASH} a patch.\n")
    patch = (
        "*** Begin Patch\n*** Add File: fresh.md\n"
        f"+Written by {EM_DASH} a patch.\n*** End Patch\n"
    )
    payload = {
        "session_id": "session",
        "cwd": str(repository),
        "tool_name": "apply_patch",
        "tool_input": {"command": patch},
    }

    response = answer_hook(monkeypatch, capsys, "post-tool-use", payload)

    assert json.loads(response) == {
        "decision": "block",
        "reason": (
            f"errors\n{repository / 'fresh.md'}:1:1 Prose.EmDash: An em dash."
            f"\n\n{ADVICE}"
        ),
    }
