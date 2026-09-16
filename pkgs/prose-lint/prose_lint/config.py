from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

DEFAULT_OWNERS = ("iainlane", "underwhelmingperformance")


@dataclass(frozen=True)
class Config:
    owners: tuple[str, ...] = DEFAULT_OWNERS

    @classmethod
    def load(cls, path: Path | None = None) -> Config:
        source = path or config_path()
        if not source.is_file():
            return cls()

        document = tomllib.loads(source.read_text())
        owners = document.get("owners")

        if not isinstance(owners, list):
            return cls()

        return cls(owners=tuple(str(owner) for owner in owners))


def config_path() -> Path:
    configured = os.environ.get("PROSE_LINT_CONFIG")
    if configured:
        return Path(configured)

    return config_home() / "prose-lint" / "config.toml"


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def state_home() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")


def share_directory() -> Path:
    """The packaged styles, base configuration and rule tiers.

    The wrapper sets PROSE_LINT_SHARE. Without it the package source tree is
    used, so the tests and the golden-file script run from a checkout.
    """
    configured = os.environ.get("PROSE_LINT_SHARE")
    if configured:
        return Path(configured)

    return Path(__file__).resolve().parent.parent
