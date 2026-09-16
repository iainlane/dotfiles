from __future__ import annotations

import re
import tomllib
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import tomli_w

from prose_lint.levels import Level
from prose_lint.rules import RuleCatalogue

_PATHLIKE = re.compile(r"[A-Za-z0-9_./-]+")


class OverrideRefused(Exception):
    """An override prose-lint will not record, with the reason for the refusal."""


@dataclass(frozen=True)
class Override:
    rule: str
    level: Level
    because: str

    def render(self) -> str:
        return f"prose-lint runs {self.rule} at {self.level.value}: {self.because}"


def build_override(
    catalogue: RuleCatalogue,
    *,
    name: str,
    because: str,
    level: Level,
    root: Path,
) -> Override:
    rule = catalogue.rule(name)

    if rule is None:
        raise OverrideRefused(f"{name} is not a rule in the Prose style.")

    if rule.locked:
        raise OverrideRefused(
            f"{name} is locked, so prose-lint cannot lower it. Decide whether the "
            "flagged prose should change or whether the rule itself is wrong."
        )

    if not _names_an_existing_path(because, root):
        raise OverrideRefused(
            f"The reason for lowering {name} names no path that exists in the "
            "repository. Name the file that records the convention."
        )

    return Override(rule=name, level=level, because=because)


def _names_an_existing_path(because: str, root: Path) -> bool:
    for candidate in _PATHLIKE.findall(because):
        if _is_file_inside(root, candidate):
            return True

    return False


def _is_file_inside(root: Path, candidate: str) -> bool:
    if not candidate.strip("./") or Path(candidate).is_absolute():
        return False

    resolved = (root / candidate).resolve()

    return resolved.is_file() and resolved.is_relative_to(root.resolve())


def read_overrides(path: Path, catalogue: RuleCatalogue) -> tuple[Override, ...]:
    if not path.exists():
        return ()

    document = tomllib.loads(path.read_text())

    return tuple(
        Override(
            rule=name,
            level=Level.parse(entry["level"]),
            because=entry["because"],
        )
        for name, entry in sorted(document.get("overrides", {}).items())
        if _is_overridable(catalogue, name)
    )


def _is_overridable(catalogue: RuleCatalogue, name: str) -> bool:
    rule = catalogue.rule(name)

    return rule is not None and not rule.locked


def write_overrides(path: Path, overrides: Iterable[Override]) -> None:
    document = {
        "overrides": {
            override.rule: {"level": override.level.value, "because": override.because}
            for override in sorted(overrides, key=lambda override: override.rule)
        }
    }

    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = path.with_name(f"{path.name}.tmp")
    scratch.write_text(tomli_w.dumps(document))
    scratch.replace(path)
