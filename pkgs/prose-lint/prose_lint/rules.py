from __future__ import annotations

import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from prose_lint.levels import Level


class Tier(Enum):
    """Whether a rule belongs to the shared style or to one writer's preference."""

    portable = "portable"
    house = "house"


class Scope(Enum):
    """The files a rule applies to."""

    all = "all"
    commit = "commit"
    code = "code"
    markdown = "markdown"


SCOPE_ORDER = (Scope.all, Scope.commit, Scope.code, Scope.markdown)

# Markup that Vale parses natively and that no scope glob lists.
_MARKUP_SUFFIXES = frozenset({".adoc", ".markdown", ".org", ".rst"})

# Formats whose comments prose-lint extracts itself. Vale has no parser for
# them, and its Perl fallback does not run the part-of-speech rules.
HASH_COMMENT_SUFFIXES = frozenset(
    {".bash", ".cfg", ".conf", ".ini", ".nix", ".sh", ".toml", ".yaml", ".yml"}
)

_GLOB = re.compile(r"^\*\.(?:\{(?P<many>[^}]+)\}|(?P<one>[A-Za-z0-9]+))$")


@dataclass(frozen=True)
class Rule:
    name: str
    tier: Tier
    level: Level
    locked: bool
    scope: Scope


@dataclass(frozen=True)
class RuleCatalogue:
    scopes: Mapping[Scope, str]
    rules: tuple[Rule, ...]

    def rule(self, name: str) -> Rule | None:
        for rule in self.rules:
            if rule.name == name:
                return rule

        return None

    def in_scope(self, scope: Scope) -> tuple[Rule, ...]:
        return tuple(rule for rule in self.rules if rule.scope is scope)

    def lintable(self, path: Path) -> bool:
        """Whether Vale has a parser for this file.

        Vale reads a file with no known format as plain text and hangs on a
        binary one, so a hook must not hand it anything outside the scope
        globs and the markup formats Vale parses itself.
        """
        return path.suffix.lower() in self.suffixes

    @property
    def suffixes(self) -> frozenset[str]:
        found: set[str] = set(_MARKUP_SUFFIXES)

        for glob in self.scopes.values():
            match = _GLOB.match(glob)
            if match is None:
                continue

            if match.group("one") is not None:
                found.add(f".{match.group('one')}")
                continue

            found.update(f".{name}" for name in match.group("many").split(","))

        return frozenset(found)

    @classmethod
    def load(cls, path: Path) -> RuleCatalogue:
        document = tomllib.loads(path.read_text())
        scopes = {
            Scope(name): glob for name, glob in document.get("scopes", {}).items()
        }
        rules = tuple(
            Rule(
                name=name,
                tier=Tier(entry["tier"]),
                level=Level.parse(entry["level"]),
                locked=bool(entry["locked"]),
                scope=Scope(entry["scope"]),
            )
            for name, entry in sorted(document.get("rules", {}).items())
        )

        return cls(scopes=scopes, rules=rules)
