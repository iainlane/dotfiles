from __future__ import annotations

from enum import Enum


class Level(Enum):
    """How loudly a rule reports, written as Vale writes it in a configuration."""

    off = "NO"
    suggestion = "suggestion"
    warning = "warning"
    error = "error"

    @property
    def rank(self) -> int:
        return _RANKS[self]

    def at_most(self, ceiling: Level) -> Level:
        if self.rank <= ceiling.rank:
            return self

        return ceiling

    @classmethod
    def parse(cls, text: str) -> Level:
        for level in cls:
            if level.value == text:
                return level

        raise ValueError(f"{text!r} is not a Vale level")


_RANKS = {
    Level.off: 0,
    Level.suggestion: 1,
    Level.warning: 2,
    Level.error: 3,
}
