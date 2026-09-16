from pathlib import Path

import pytest

from prose_lint.commit_command import extract_commit_message

HEREDOC_QUOTED = """git commit -F - <<'EOF'
fix(db): index foo by quux

The query scanned the whole table.
EOF"""

HEREDOC_BARE = """git add -A && git commit --file=- <<MSG
fix(db): index foo by quux

The query scanned the whole table.
MSG
echo done"""

HEREDOC_BODY = "fix(db): index foo by quux\n\nThe query scanned the whole table.\n"

SUBSTITUTED = """git commit -m "$(cat <<'MSG'
fix(db): index foo by quux

The query scanned the whole table.
MSG
)\""""


@pytest.mark.parametrize(
    ("command", "expected"),
    [
        ('git commit -m "one line"', "one line"),
        ("git commit -m'one line'", "one line"),
        ('git commit --message="one line"', "one line"),
        ('git commit -am "one line"', "one line"),
        ('git commit -m "subject" -m "body"', "subject\n\nbody"),
        ('git -C /tmp/work commit -m "subject" -m "body"', "subject\n\nbody"),
        ('cd /tmp && git commit -m "subject"', "subject"),
        (HEREDOC_QUOTED, HEREDOC_BODY),
        (HEREDOC_BARE, HEREDOC_BODY),
        (SUBSTITUTED, HEREDOC_BODY),
        ("git commit -msome message", "some"),
        ("PAGER=cat git commit -m subject", "subject"),
        ('printf "%s" git commit -m "some prose"', None),
        ("git commit", None),
        ("git commit --amend --no-edit", None),
        ('git log --format="%s"', None),
        ('echo "git commit -m ohno"', None),
    ],
)
def test_the_message_is_read_from_every_inline_form(
    command: str, expected: str | None, tmp_path: Path
) -> None:
    assert extract_commit_message(command, tmp_path) == expected


def test_a_message_file_is_read_relative_to_the_working_directory(
    tmp_path: Path,
) -> None:
    (tmp_path / "message.txt").write_text("fix(db): index foo by quux\n")

    assert (
        extract_commit_message("git commit -F message.txt", tmp_path)
        == "fix(db): index foo by quux\n"
    )


def test_a_missing_message_file_reads_as_no_message(tmp_path: Path) -> None:
    assert extract_commit_message("git commit -F absent.txt", tmp_path) is None


def test_an_attached_file_option_is_a_file_and_not_a_message(tmp_path: Path) -> None:
    (tmp_path / "myfile").write_text("fix(db): index foo by quux\n")

    assert (
        extract_commit_message("git commit -Fmyfile", tmp_path)
        == "fix(db): index foo by quux\n"
    )


def test_an_unreadable_message_file_reads_as_no_message(tmp_path: Path) -> None:
    (tmp_path / "binary.txt").write_bytes(b"\xff\xfe not text")

    assert extract_commit_message("git commit -F binary.txt", tmp_path) is None
