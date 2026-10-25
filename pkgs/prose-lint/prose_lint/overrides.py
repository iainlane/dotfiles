from __future__ import annotations

import re
import tomllib
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

import tomli_w
from pathspec import GitIgnoreSpec

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
    files: tuple[str, ...] | None = None
    _spec: GitIgnoreSpec | None = field(
        init=False, default=None, repr=False, compare=False
    )

    def __post_init__(self) -> None:
        if self.files is None:
            return

        if not self.files:
            raise OverrideRefused("files must be a non-empty list of patterns.")

        try:
            spec = GitIgnoreSpec.from_lines(self.files)
        except ValueError as error:
            raise OverrideRefused(
                f"Invalid file pattern for {self.rule}: {error}"
            ) from error

        object.__setattr__(self, "_spec", spec)

    def applies_to(self, relative_path: str | None) -> bool:
        if self._spec is None:
            return True

        return relative_path is not None and self._spec.match_file(relative_path)

    def render(self) -> str:
        scope = f" for {list(self.files)!r}" if self.files is not None else ""

        return (
            f"prose-lint runs {self.rule} at {self.level.value}{scope}: {self.because}"
        )


def build_override(
    catalogue: RuleCatalogue,
    *,
    name: str,
    because: str,
    level: Level,
    root: Path,
    files: Sequence[str] | None = None,
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
            f"The reason for lowering {name} must mention a path that exists "
            "in the repository, so the override points at the file that "
            "records the convention."
        )

    return Override(
        rule=name,
        level=level,
        because=because,
        files=tuple(files) if files is not None else None,
    )


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
            files=_read_files(entry.get("files")),
        )
        for name, entry in sorted(document.get("overrides", {}).items())
        if _is_overridable(catalogue, name)
    )


def _read_files(value: object) -> tuple[str, ...] | None:
    if value is None:
        return None

    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise OverrideRefused("files must be a non-empty list of patterns.")

    return tuple(value)


def _is_overridable(catalogue: RuleCatalogue, name: str) -> bool:
    rule = catalogue.rule(name)

    return rule is not None and not rule.locked


def write_overrides(path: Path, overrides: Iterable[Override]) -> None:
    document = {
        "overrides": {
            override.rule: {
                "level": override.level.value,
                "because": override.because,
                **(
                    {"files": list(override.files)}
                    if override.files is not None
                    else {}
                ),
            }
            for override in sorted(overrides, key=lambda override: override.rule)
        }
    }

    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = path.with_name(f"{path.name}.tmp")
    scratch.write_text(tomli_w.dumps(document))
    scratch.replace(path)
