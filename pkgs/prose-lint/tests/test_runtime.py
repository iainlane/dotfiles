from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from prose_lint.config import Config
from prose_lint.report import Finding
from prose_lint.rules import RuleCatalogue
from prose_lint.runtime import Runtime
from prose_lint.vale import ValeInvocation

SOURCE = Path(__file__).resolve().parent.parent


@dataclass
class FakeGit:
    """A git repository with no remotes, standing in for the real one."""

    root_path: Path
    urls: tuple[str, ...] = ()
    counts: dict[str, int] = field(default_factory=dict)

    def root(self) -> Path | None:
        return self.root_path

    def common_directory(self) -> Path | None:
        return self.root_path / ".git"

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


@pytest.fixture
def runtime(tmp_path: Path) -> Runtime:
    return Runtime(
        share=SOURCE,
        catalogue=RuleCatalogue.load(SOURCE / "tiers.toml"),
        config=Config(),
        git=FakeGit(root_path=tmp_path),
        vale=RecordingVale(),
        cwd=tmp_path,
    )


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
