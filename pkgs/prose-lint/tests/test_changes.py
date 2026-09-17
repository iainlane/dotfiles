import os
import subprocess
from pathlib import Path

import pytest

from prose_lint.changes import added_lines
from prose_lint.git import SubprocessGit


def git(repository: Path, *arguments: str) -> None:
    subprocess.run(
        ["git", *arguments],
        cwd=repository,
        check=True,
        capture_output=True,
        env={
            **os.environ,
            "HOME": str(repository),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_AUTHOR_NAME": "prose-lint",
            "GIT_AUTHOR_EMAIL": "prose-lint@example.invalid",
            "GIT_COMMITTER_NAME": "prose-lint",
            "GIT_COMMITTER_EMAIL": "prose-lint@example.invalid",
        },
    )


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    git(tmp_path, "init", "--initial-branch=main")
    (tmp_path / "notes.md").write_text("One.\nTwo.\nThree.\n")
    git(tmp_path, "add", "notes.md")
    git(tmp_path, "commit", "--message", "add notes")

    return tmp_path


def test_the_working_tree_reports_its_changed_files_and_added_lines(
    repository: Path,
) -> None:
    (repository / "notes.md").write_text("One.\nTwo again.\nThree.\nFour.\n")
    (repository / "fresh.md").write_text("New.\n")
    reader = SubprocessGit(cwd=repository)

    assert (
        reader.changed_paths(),
        reader.untracked_paths(),
        added_lines(reader.diff_against_head(Path("notes.md"))),
    ) == ((Path("notes.md"),), (Path("fresh.md"),), frozenset({2, 4}))


def test_a_deletion_adds_no_line(repository: Path) -> None:
    (repository / "notes.md").write_text("One.\nThree.\n")
    reader = SubprocessGit(cwd=repository)

    assert added_lines(reader.diff_against_head(Path("notes.md"))) == frozenset()
