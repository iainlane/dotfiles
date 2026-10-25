from pathlib import Path

import pytest

from prose_lint.levels import Level
from prose_lint.overrides import (
    Override,
    OverrideRefused,
    build_override,
    read_overrides,
    write_overrides,
)
from prose_lint.rules import Rule, RuleCatalogue, Scope, Tier

CATALOGUE = RuleCatalogue(
    scopes={Scope.all: "*"},
    rules=(
        Rule("ArrowChain", Tier.portable, Level.error, locked=True, scope=Scope.all),
        Rule("Latin", Tier.house, Level.warning, locked=False, scope=Scope.all),
    ),
)


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "style.md").write_text(
        "Latin abbreviations are house style.\n"
    )
    return tmp_path


def test_a_reason_naming_a_file_in_the_repository_produces_an_override(
    repository: Path,
) -> None:
    override = build_override(
        CATALOGUE,
        name="Latin",
        because="docs/style.md asks for e.g. in tables.",
        level=Level.warning,
        root=repository,
    )

    assert override == Override(
        rule="Latin",
        level=Level.warning,
        because="docs/style.md asks for e.g. in tables.",
    )


def test_a_locked_rule_is_refused(repository: Path) -> None:
    with pytest.raises(OverrideRefused) as refusal:
        build_override(
            CATALOGUE,
            name="ArrowChain",
            because="docs/style.md uses arrows in tables.",
            level=Level.warning,
            root=repository,
        )

    assert str(refusal.value) == (
        "ArrowChain is locked, so prose-lint cannot lower it. Decide whether the "
        "flagged prose should change or whether the rule itself is wrong."
    )


def test_a_reason_naming_no_file_in_the_repository_is_refused(
    repository: Path,
) -> None:
    with pytest.raises(OverrideRefused) as refusal:
        build_override(
            CATALOGUE,
            name="Latin",
            because="the maintainers prefer it",
            level=Level.warning,
            root=repository,
        )

    assert str(refusal.value) == (
        "The reason for lowering Latin must mention a path that exists "
        "in the repository, so the override points at the file that "
        "records the convention."
    )


def test_an_unknown_rule_is_refused(repository: Path) -> None:
    with pytest.raises(OverrideRefused) as refusal:
        build_override(
            CATALOGUE,
            name="Nonexistent",
            because="docs/style.md",
            level=Level.warning,
            root=repository,
        )

    assert str(refusal.value) == "Nonexistent is not a rule in the Prose style."


@pytest.mark.parametrize(
    "because",
    [
        "/etc/hosts records the convention",
        "docs records the convention",
        "../outside.md records the convention",
    ],
)
def test_evidence_must_be_a_file_inside_the_repository(
    repository: Path, because: str
) -> None:
    (repository.parent / "outside.md").write_text("x\n")

    with pytest.raises(OverrideRefused, match="must mention a path"):
        build_override(
            CATALOGUE,
            name="Latin",
            because=because,
            level=Level.warning,
            root=repository,
        )


def test_overrides_round_trip_through_the_file(tmp_path: Path) -> None:
    path = tmp_path / "info" / "prose-lint.toml"
    override = Override(rule="Latin", level=Level.warning, because="docs/style.md")

    write_overrides(path, [override])

    assert (
        read_overrides(path, CATALOGUE),
        sorted(p.name for p in path.parent.iterdir()),
    ) == (
        (override,),
        ["prose-lint.toml"],
    )


def test_a_hand_written_override_of_a_locked_rule_is_ignored(tmp_path: Path) -> None:
    path = tmp_path / "prose-lint.toml"
    path.write_text(
        '[overrides.ArrowChain]\nlevel = "NO"\nbecause = "docs/style.md"\n'
        '[overrides.Latin]\nlevel = "NO"\nbecause = "docs/style.md"\n'
    )

    assert read_overrides(path, CATALOGUE) == (
        Override(rule="Latin", level=Level.off, because="docs/style.md"),
    )


@pytest.mark.parametrize("files", [None, ("docs/**/*.md", "!docs/generated/**")])
def test_file_scopes_round_trip_without_changing_legacy_entries(
    tmp_path: Path, files: tuple[str, ...] | None
) -> None:
    path = tmp_path / "prose-lint.toml"
    override = Override("Latin", Level.off, "docs/style.md", files=files)

    write_overrides(path, (override,))

    assert read_overrides(path, CATALOGUE) == (override,)
    assert ("files =" in path.read_text()) == (files is not None)


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        (None, (True, True, True, True)),
        (("docs/**/*.md", "!docs/generated/**"), (False, True, True, False)),
        (("*.md",), (True, True, True, True)),
        (("/README.md",), (True, False, False, False)),
        (("docs/", "!docs/nested/page.md"), (False, True, False, True)),
        (("future/**/*.md",), (False, False, False, False)),
    ],
)
def test_scopes_use_ordered_pathspec_matching(
    files: tuple[str, ...] | None, expected: tuple[bool, ...]
) -> None:
    override = Override("Latin", Level.off, "docs/style.md", files=files)

    assert (
        tuple(
            override.applies_to(path)
            for path in (
                "README.md",
                "docs/page.md",
                "docs/nested/page.md",
                "docs/generated/page.md",
            )
        )
        == expected
    )


@pytest.mark.parametrize(
    "files",
    ["[]", '"docs/**"', "[1]", '["docs/**", false]', '["invalid\\\\"]'],
)
def test_invalid_file_scopes_are_refused_when_read(tmp_path: Path, files: str) -> None:
    path = tmp_path / "prose-lint.toml"
    path.write_text(
        f'[overrides.Latin]\nlevel = "NO"\nbecause = "docs/style.md"\nfiles = {files}\n'
    )

    with pytest.raises(OverrideRefused, match="files|pattern"):
        read_overrides(path, CATALOGUE)


def test_scoped_rendering_includes_the_patterns_in_order() -> None:
    override = Override(
        "Latin", Level.off, "docs/style.md", files=("docs/**", "!docs/generated/**")
    )

    assert override.render() == (
        "prose-lint runs Latin at NO for ['docs/**', '!docs/generated/**']: "
        "docs/style.md"
    )
