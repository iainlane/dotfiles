import pytest

from prose_lint.levels import Level
from prose_lint.policy import effective_levels
from prose_lint.rules import Rule, RuleCatalogue, Scope, Tier
from prose_lint.spelling import SpellingVariant

CATALOGUE = RuleCatalogue(
    scopes={
        Scope.all: "*",
        Scope.commit: "*.txt",
        Scope.code: "*.nix",
        Scope.markdown: "*.md",
    },
    rules=(
        Rule("ArrowChain", Tier.portable, Level.error, locked=True, scope=Scope.all),
        Rule("Latin", Tier.house, Level.warning, locked=False, scope=Scope.all),
        Rule("Trailers", Tier.house, Level.error, locked=False, scope=Scope.commit),
        Rule(
            "BritishSpelling",
            Tier.house,
            Level.warning,
            locked=False,
            scope=Scope.all,
        ),
        Rule(
            "AmericanSpelling",
            Tier.house,
            Level.warning,
            locked=False,
            scope=Scope.all,
        ),
    ),
)


def test_an_owned_repository_keeps_the_configured_house_levels() -> None:
    assert effective_levels(
        CATALOGUE,
        owned=True,
        variant=SpellingVariant.british,
        overrides={},
    ) == {
        "ArrowChain": Level.error,
        "Latin": Level.warning,
        "Trailers": Level.error,
        "BritishSpelling": Level.warning,
        "AmericanSpelling": Level.off,
    }


def test_an_external_repository_caps_house_rules_at_warning() -> None:
    assert effective_levels(
        CATALOGUE,
        owned=False,
        variant=SpellingVariant.american,
        overrides={},
    ) == {
        "ArrowChain": Level.error,
        "Latin": Level.warning,
        "Trailers": Level.warning,
        "BritishSpelling": Level.off,
        "AmericanSpelling": Level.warning,
    }


def test_neither_spelling_rule_runs_without_a_detected_variant() -> None:
    assert effective_levels(
        CATALOGUE,
        owned=True,
        variant=SpellingVariant.undecided,
        overrides={},
    ) == {
        "ArrowChain": Level.error,
        "Latin": Level.warning,
        "Trailers": Level.error,
        "BritishSpelling": Level.off,
        "AmericanSpelling": Level.off,
    }


@pytest.mark.parametrize(
    ("override", "expected"),
    [
        (Level.warning, Level.warning),
        (Level.off, Level.off),
        (Level.error, Level.error),
    ],
)
def test_an_override_never_raises_a_rule_above_its_configured_level(
    override: Level, expected: Level
) -> None:
    levels = effective_levels(
        CATALOGUE,
        owned=True,
        variant=SpellingVariant.british,
        overrides={"Trailers": override},
    )

    assert levels["Trailers"] == expected


def test_an_override_of_a_locked_rule_has_no_effect() -> None:
    levels = effective_levels(
        CATALOGUE,
        owned=True,
        variant=SpellingVariant.british,
        overrides={"ArrowChain": Level.off},
    )

    assert levels["ArrowChain"] == Level.error
