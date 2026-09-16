from pathlib import Path

import pytest

from prose_lint.configuration import render_configuration
from prose_lint.levels import Level
from prose_lint.rules import Rule, RuleCatalogue, Scope, Tier

CATALOGUE = RuleCatalogue(
    scopes={
        Scope.all: "*",
        Scope.commit: "*.txt",
        Scope.code: "*.{nix,py}",
        Scope.markdown: "*.md",
    },
    rules=(
        Rule("ArrowChain", Tier.portable, Level.error, locked=True, scope=Scope.all),
        Rule(
            "BoldLabelBullets",
            Tier.portable,
            Level.warning,
            locked=False,
            scope=Scope.markdown,
        ),
        Rule(
            "ReviewRationale",
            Tier.portable,
            Level.error,
            locked=True,
            scope=Scope.code,
        ),
        Rule("Trailers", Tier.house, Level.error, locked=False, scope=Scope.commit),
    ),
)

BASE = (
    "StylesPath = /store/styles\n"
    "\n"
    "[*]\n"
    "BasedOnStyles = Prose\n"
    "Prose.Trailers = NO\n"
    "\n"
    "[*.txt]\n"
    "Prose.Trailers = error\n"
)


def test_each_rule_is_set_in_the_section_that_scopes_it() -> None:
    levels = {
        "ArrowChain": Level.error,
        "BoldLabelBullets": Level.warning,
        "ReviewRationale": Level.error,
        "Trailers": Level.off,
    }

    assert render_configuration(BASE, CATALOGUE, levels) == (
        "StylesPath = /store/styles\n"
        "\n"
        "[*]\n"
        "BasedOnStyles = Prose\n"
        "\n"
        "[*.txt]\n"
        "\n"
        "[*]\n"
        "Prose.ArrowChain = error\n"
        "Prose.BoldLabelBullets = NO\n"
        "Prose.ReviewRationale = NO\n"
        "Prose.Trailers = NO\n"
        "\n"
        "[*.txt]\n"
        "Prose.Trailers = NO\n"
        "\n"
        "[*.{nix,py}]\n"
        "Prose.ReviewRationale = error\n"
        "\n"
        "[*.md]\n"
        "Prose.BoldLabelBullets = warning\n"
    )


def test_the_packaged_catalogue_matches_the_packaged_style_and_config() -> None:
    source = Path(__file__).resolve().parent.parent
    catalogue = RuleCatalogue.load(source / "tiers.toml")
    base = (source / "vale.ini.in").read_text()

    missing_sections = [
        glob for glob in catalogue.scopes.values() if f"[{glob}]" not in base
    ]
    missing_rules = [
        rule.name
        for rule in catalogue.rules
        if not (source / "styles" / "Prose" / f"{rule.name}.yml").exists()
    ]
    unlisted_rules = sorted(
        path.stem
        for path in (source / "styles" / "Prose").glob("*.yml")
        if catalogue.rule(path.stem) is None
    )

    assert (missing_sections, missing_rules, unlisted_rules) == ([], [], [])


def test_the_lintable_suffixes_come_from_the_scope_globs() -> None:
    assert CATALOGUE.suffixes == frozenset(
        {".adoc", ".markdown", ".md", ".nix", ".org", ".py", ".rst", ".txt"}
    )


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        (Path("docs/guide.md"), True),
        (Path("module.NIX"), True),
        (Path("notes.txt"), True),
        (Path("flake.lock"), False),
        (Path("image.png"), False),
        (Path("Makefile"), False),
    ],
)
def test_lintable_is_decided_by_suffix(path: Path, expected: bool) -> None:
    assert CATALOGUE.lintable(path) is expected
