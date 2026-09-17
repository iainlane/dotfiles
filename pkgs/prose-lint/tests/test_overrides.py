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
        "The reason for lowering Latin must quote a path that exists in "
        "the repository, so the override points at the file that records "
        "the convention."
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

    with pytest.raises(OverrideRefused, match="must quote a path"):
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
