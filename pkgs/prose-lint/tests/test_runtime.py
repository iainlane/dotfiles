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
class LineVale:
    """A vale that reports one finding on each of `lines`, for every file."""

    lines: tuple[int, ...]

    def lint(self, invocation: ValeInvocation) -> tuple[Finding, ...]:
        paths = invocation.paths or (Path(invocation.path_hint or ""),)

        return tuple(
            em_dash(path, line) for path in paths for line in sorted(self.lines)
        )


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


def test_hash_comment_files_are_read_as_markdown_with_their_path(
    runtime: Runtime, tmp_path: Path
) -> None:
    module = tmp_path / "module.nix"
    module.write_text("# A comment.\nx = 1;\n")
    readme = tmp_path / "README.md"
    readme.write_text("Prose.\n")

    runtime.lint_paths((module, readme))

    vale = runtime.vale
    assert isinstance(vale, RecordingVale)
    assert [
        (i.paths, i.stdin_text, i.extension, i.path_hint) for i in vale.invocations
    ] == [
        ((readme,), None, None, None),
        ((), "A comment.\n\n", ".md", str(module)),
    ]


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
    module.write_text("# A comment.\n")
    runtime = build_runtime(tmp_path, BrokenFileVale(broken=module))

    report = runtime.lint_paths((module,))

    assert report.findings == (failure_finding(module),)


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
