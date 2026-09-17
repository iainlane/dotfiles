from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from prose_lint.config import Config
from prose_lint.levels import Level
from prose_lint.report import Finding
from prose_lint.rules import RuleCatalogue
from prose_lint.runtime import Runtime
from prose_lint.vale import Vale, ValeFailed, ValeInvocation

SOURCE = Path(__file__).resolve().parent.parent


@dataclass
class FakeGit:
    """A git repository with no remotes, standing in for the real one."""

    root_path: Path | None
    urls: tuple[str, ...] = ()
    counts: dict[str, int] = field(default_factory=dict)
    changed: tuple[Path, ...] = ()
    untracked: tuple[Path, ...] = ()
    diffs: dict[Path, str] = field(default_factory=dict)
    staged: dict[Path, str] = field(default_factory=dict)

    def root(self) -> Path | None:
        return self.root_path

    def common_directory(self) -> Path | None:
        return None if self.root_path is None else self.root_path / ".git"

    def changed_paths(self) -> tuple[Path, ...]:
        return self.changed

    def untracked_paths(self) -> tuple[Path, ...]:
        return self.untracked

    def diff_against_head(self, path: Path) -> str:
        return self.diffs.get(path, "")

    def diff_staged(self, path: Path) -> str:
        return self.staged.get(path, "")

    def remote_urls(self) -> tuple[str, ...]:
        return self.urls

    def count_matches(self, pattern: str, pathspec: Sequence[str] = ()) -> int:
        del pathspec
        return self.counts.get(pattern, 0)


@dataclass
class RecordingVale:
    invocations: list[ValeInvocation] = field(default_factory=list)

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        self.invocations.append(invocation)
        return ()


FAILURE = "vale exited 2: yaml: line 5: could not find expected ':'"


@dataclass
class BrokenFileVale:
    """A vale that fails on one path and reports one alert for every other."""

    broken: Path

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        paths = invocation.paths or (Path(invocation.path_hint or ""),)

        if self.broken in paths:
            raise ValeFailed(FAILURE)

        return tuple(
            Finding(
                path=str(path),
                line=2,
                column=1,
                rule="Prose.EmDash",
                message="An em dash.",
                severity=Level.error,
            )
            for path in paths
        )


@dataclass
class BrokenContentVale:
    """A vale that fails on a file containing `broken` and reports on every other."""

    broken: str

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        if any(self.broken in path.read_text() for path in invocation.paths):
            raise ValeFailed(FAILURE)

        return tuple(em_dash(path, 1) for path in invocation.paths)


@dataclass
class LineVale:
    """A vale that reports one finding on each of `lines`, for every file."""

    lines: tuple[int, ...]

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        paths = invocation.paths or (Path(invocation.path_hint or ""),)

        return tuple(
            em_dash(path, line) for path in paths for line in sorted(self.lines)
        )


@dataclass
class RelativeClauseVale:
    """A vale that reports one relative-clause alert on line 1 of every file."""

    match: str

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        return tuple(relative_clause(path, self.match) for path in invocation.paths)


def relative_clause(path: Path, match: str) -> Finding:
    return Finding(
        path=str(path),
        line=1,
        column=1,
        rule="Prose.ZeroRelative",
        message="An object-relative clause.",
        severity=Level.error,
        match=match,
    )


@dataclass
class MirrorVale:
    """A vale that records what each invocation asked it to read.

    A file Vale reads for itself is recorded by its path and a mirror file by
    its contents, because a mirror's own name is a scratch name.
    """

    invocations: list[tuple[tuple[str, ...], str | None]] = field(default_factory=list)

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        read = tuple(
            path.read_text() if invocation.extension == ".md" else str(path)
            for path in invocation.paths
        )
        self.invocations.append((read, invocation.extension))

        return ()


def em_dash(path: Path, line: int) -> Finding:
    return Finding(
        path=str(path),
        line=line,
        column=1,
        rule="Prose.EmDash",
        message="An em dash.",
        severity=Level.error,
    )


def build_runtime(tmp_path: Path, vale: Vale, git: FakeGit | None = None) -> Runtime:
    return Runtime(
        share=SOURCE,
        catalogue=RuleCatalogue.load(SOURCE / "tiers.toml"),
        config=Config(),
        git=git or FakeGit(root_path=tmp_path),
        vale=vale,
        cwd=tmp_path,
    )


@pytest.fixture
def runtime(tmp_path: Path) -> Runtime:
    return build_runtime(tmp_path, RecordingVale())


def section(text: str, header: str) -> list[str]:
    """The last section under `header`, which is the one prose-lint appended."""
    sections: list[list[str]] = []
    collecting = False

    for line in text.splitlines():
        if line.startswith("["):
            collecting = line == header
            if collecting:
                sections.append([])
            continue

        if collecting and line.strip():
            sections[-1].append(line)

    return sections[-1] if sections else []


def test_a_commit_message_is_linted_as_text_from_standard_input(
    runtime: Runtime,
) -> None:
    vale = runtime.vale
    assert isinstance(vale, RecordingVale)

    runtime.lint_commit_message("fix(db): index foo by quux\n", "commit message")
    invocation = vale.invocations[0]

    assert (
        invocation.paths,
        invocation.stdin_text,
        invocation.extension,
        invocation.display_path,
    ) == ((), "fix(db): index foo by quux\n", ".txt", "commit message")


def test_the_commit_section_enables_only_the_commit_rules(runtime: Runtime) -> None:
    rendered = runtime.configuration().read_text()

    assert section(rendered, "[*.txt]") == [
        "Prose.Chronology = warning",
        "Prose.DiffWalkthrough = warning",
        "Prose.PrTalk = warning",
        "Prose.Trailers = error",
    ]


def test_the_commit_rules_are_off_outside_a_commit_message(runtime: Runtime) -> None:
    rendered = runtime.configuration().read_text()
    everywhere = section(rendered, "[*]")

    assert [line for line in everywhere if "= NO" in line] == [
        "Prose.AmericanSpelling = NO",
        "Prose.BoldLabelBullets = NO",
        "Prose.Chronology = NO",
        "Prose.DiffWalkthrough = NO",
        "Prose.PrTalk = NO",
        "Prose.ReviewRationale = NO",
        "Prose.Trailers = NO",
    ]


def test_hash_comment_files_are_mirrored_as_markdown_for_one_run(
    tmp_path: Path,
) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# A comment.\nx = 1;\n")
    script = tmp_path / "build.sh"
    script.write_text("# Another comment.\n")
    readme = tmp_path / "README.md"
    readme.write_text("Prose.\n")
    vale = MirrorVale()
    runtime = build_runtime(tmp_path, vale)

    runtime.lint_paths((module, script, readme))

    assert vale.invocations == [
        ((str(readme),), None),
        (("A comment.\n\n", "Another comment.\n"), ".md"),
    ]


def test_an_alert_on_a_mirror_is_reported_against_the_file_it_came_from(
    tmp_path: Path,
) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# A comment.\nx = 1;\n")
    script = tmp_path / "build.sh"
    script.write_text("# Another comment.\n")
    runtime = build_runtime(tmp_path, LineVale(lines=(1,)))

    assert runtime.lint_paths((module, script)).findings == (
        em_dash(module, 1),
        em_dash(script, 1),
    )


def failure_finding(path: Path) -> Finding:
    return Finding(
        path=str(path),
        line=1,
        column=1,
        rule="prose-lint",
        message=FAILURE,
        severity=Level.error,
    )


def test_a_file_vale_cannot_read_is_reported_and_the_rest_are_still_linted(
    tmp_path: Path,
) -> None:
    broken = tmp_path / "broken.md"
    broken.write_text("Prose.\n")
    readable = tmp_path / "readable.md"
    readable.write_text("Prose.\n")
    runtime = build_runtime(tmp_path, BrokenFileVale(broken=broken))

    report = runtime.lint_paths((broken, readable))

    assert report.findings == (
        failure_finding(broken),
        Finding(
            path=str(readable),
            line=2,
            column=1,
            rule="Prose.EmDash",
            message="An em dash.",
            severity=Level.error,
        ),
    )


def test_a_hash_comment_file_vale_cannot_read_is_reported_the_same_way(
    tmp_path: Path,
) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# Malformed.\n")
    runtime = build_runtime(tmp_path, BrokenContentVale(broken="Malformed."))

    report = runtime.lint_paths((module,))

    assert report.findings == (failure_finding(module),)


def test_one_unreadable_mirror_leaves_the_others_linted(tmp_path: Path) -> None:
    broken = tmp_path / "broken.nix"
    broken.write_text("# Malformed.\n")
    readable = tmp_path / "readable.nix"
    readable.write_text("# A comment.\n")
    runtime = build_runtime(tmp_path, BrokenContentVale(broken="Malformed."))

    report = runtime.lint_paths((broken, readable))

    assert report.findings == (failure_finding(broken), em_dash(readable, 1))


def test_only_the_lines_added_since_head_are_reported(tmp_path: Path) -> None:
    notes = tmp_path / "notes.md"
    notes.write_text("One.\nTwo.\nThree.\n")
    runtime = build_runtime(
        tmp_path,
        LineVale(lines=(1, 2, 3)),
        FakeGit(
            root_path=tmp_path,
            changed=(Path("notes.md"),),
            diffs={Path("notes.md"): "@@ -2 +2 @@\n-Two.\n+Two again.\n"},
        ),
    )

    assert runtime.lint_added_lines().findings == (em_dash(notes, 2),)


def test_every_line_of_an_untracked_file_counts_as_added(tmp_path: Path) -> None:
    fresh = tmp_path / "fresh.md"
    fresh.write_text("One.\nTwo.\n")
    runtime = build_runtime(
        tmp_path,
        LineVale(lines=(1, 2)),
        FakeGit(root_path=tmp_path, untracked=(Path("fresh.md"),)),
    )

    assert runtime.lint_added_lines().findings == (
        em_dash(fresh, 1),
        em_dash(fresh, 2),
    )


def test_nothing_is_linted_outside_a_git_repository(tmp_path: Path) -> None:
    (tmp_path / "notes.md").write_text("One.\n")
    runtime = build_runtime(
        tmp_path, LineVale(lines=(1,)), FakeGit(root_path=None, untracked=())
    )

    assert runtime.lint_added_lines().findings == ()


def test_nothing_is_staged_outside_a_git_repository(tmp_path: Path) -> None:
    notes = tmp_path / "notes.md"
    notes.write_text("One.\n")
    runtime = build_runtime(tmp_path, LineVale(lines=(1,)), FakeGit(root_path=None))

    assert runtime.lint_staged_lines((notes,)).findings == ()


def test_a_fronted_adverbial_in_a_comment_is_not_reported(tmp_path: Path) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# Outside a git repository the hook has no HEAD.\n")
    runtime = build_runtime(tmp_path, RelativeClauseVale("repository the hook has"))

    assert runtime.lint_paths((module,)).findings == ()


def test_a_relative_clause_in_a_comment_is_reported(tmp_path: Path) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# The operating system the machine runs is chosen here.\n")
    runtime = build_runtime(tmp_path, RelativeClauseVale("system the machine runs"))

    assert runtime.lint_paths((module,)).findings == (
        relative_clause(module, "system the machine runs"),
    )


def test_a_fronted_adverbial_in_a_commit_message_is_not_reported(
    tmp_path: Path,
) -> None:
    runtime = build_runtime(tmp_path, RelativeClauseVale("stop the agent closes"))

    report = runtime.lint_commit_message(
        "On stop the agent closes the transcript.\n", "commit message"
    )

    assert report.findings == ()


def test_a_mistagged_adverbial_in_a_comment_is_not_reported(tmp_path: Path) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# The lint no longer objects.\n")
    runtime = build_runtime(tmp_path, RelativeClauseVale("The lint no longer objects"))

    assert runtime.lint_paths((module,)).findings == ()


UNDECODABLE = "'utf-8' codec can't decode byte 0xff in position 13: invalid start byte"


def test_a_hash_comment_file_that_is_not_utf8_is_reported_against_itself(
    tmp_path: Path,
) -> None:
    undecodable = tmp_path / "broken.nix"
    undecodable.write_bytes(b"# A comment.\n\xff\xfe\n")
    readable = tmp_path / "readable.nix"
    readable.write_text("# A comment.\n")
    runtime = build_runtime(tmp_path, LineVale(lines=(1,)))

    assert runtime.lint_paths((undecodable, readable)).findings == (
        em_dash(readable, 1),
        Finding(
            path=str(undecodable),
            line=1,
            column=1,
            rule="prose-lint",
            message=UNDECODABLE,
            severity=Level.error,
        ),
    )
