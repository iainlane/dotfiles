import os
import subprocess
from pathlib import Path

import pytest


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
