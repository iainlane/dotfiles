from __future__ import annotations

from collections.abc import Mapping

from prose_lint.levels import Level
from prose_lint.rules import RuleCatalogue, Tier
from prose_lint.spelling import SpellingVariant

_VARIANT_RULES = {
    SpellingVariant.british: "BritishSpelling",
    SpellingVariant.american: "AmericanSpelling",
}


def effective_levels(
    catalogue: RuleCatalogue,
    *,
    owned: bool,
    variant: SpellingVariant,
    overrides: Mapping[str, Level],
) -> dict[str, Level]:
    """The level each rule runs at here.

    A house rule is one writer's preference, so outside that writer's own
    repositories it is capped at warning and cannot fail a check. An override
    only ever lowers a rule.
    """
    wanted = _VARIANT_RULES.get(variant)
    levels: dict[str, Level] = {}

    for rule in catalogue.rules:
        level = rule.level

        if rule.tier is Tier.house and not owned:
            level = level.at_most(Level.warning)

        if rule.name in _VARIANT_RULES.values() and rule.name != wanted:
            level = Level.off

        override = overrides.get(rule.name)
        if override is not None and not rule.locked:
            level = level.at_most(override)

        levels[rule.name] = level

    return levels
