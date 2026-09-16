from __future__ import annotations

import re
from collections.abc import Iterable, Mapping

from prose_lint.levels import Level
from prose_lint.rules import SCOPE_ORDER, Rule, RuleCatalogue, Scope

_RULE_LINE = re.compile(r"^\s*Prose\.[A-Za-z0-9]+\s*=")


def render_configuration(
    base: str,
    catalogue: RuleCatalogue,
    levels: Mapping[str, Level],
) -> str:
    """The packaged Vale configuration with this run's levels in place of its own.

    Vale keeps the first value it reads for a key, so a second [*] section
    cannot shadow a level the packaged file already sets. The packaged levels
    are therefore removed before the new sections are appended.

    Within one file Vale takes the level from the last section that sets it and
    the enabled flag from the most specific section that matches. A rule with
    a narrower scope is therefore switched off in [*] and switched on at its
    level in the section for its scope.
    """
    kept = [line for line in base.splitlines() if not _RULE_LINE.match(line)]
    sections: list[str] = []

    for scope in SCOPE_ORDER:
        glob = catalogue.scopes.get(scope)
        if glob is None:
            continue

        lines = [
            f"Prose.{rule.name} = {_level_for(rule, scope, levels[rule.name])}"
            for rule in _rules_for(catalogue, scope)
        ]

        if not lines:
            continue

        sections.append("\n".join([f"[{glob}]", *lines]))

    return "\n".join(kept).rstrip("\n") + "\n\n" + "\n\n".join(sections) + "\n"


def _rules_for(catalogue: RuleCatalogue, scope: Scope) -> Iterable[Rule]:
    if scope is Scope.all:
        return catalogue.rules

    return catalogue.in_scope(scope)


def _level_for(rule: Rule, section: Scope, level: Level) -> str:
    if section is Scope.all and rule.scope is not Scope.all:
        return Level.off.value

    return level.value
