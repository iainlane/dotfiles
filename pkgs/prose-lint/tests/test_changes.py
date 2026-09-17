from pathlib import Path

from prose_lint.changes import added_lines
from prose_lint.git import SubprocessGit


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
