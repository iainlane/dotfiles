from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Protocol


class ConfigContext(Protocol):
    def get_config(self, key: str, default: Any = None) -> Any: ...


@dataclass(frozen=True)
class Settings:
    inbox_id: str
    board_id: str
    assignee: str
    matrix_room_id: str
    matrix_user_id: str
    digest_limit: int = 10
    body_limit: int = 60_000

    @classmethod
    def from_context(cls, ctx: ConfigContext) -> Settings:
        digest_limit = _integer(ctx, "digest_limit", 10)
        if not 1 <= digest_limit <= 10:
            raise ValueError("digest_limit must be between 1 and 10")

        return cls(
            inbox_id=_required(ctx, "inbox_id"),
            board_id=_string(ctx, "board_id", "default"),
            assignee=_string(ctx, "assignee", "default"),
            matrix_room_id=_required(ctx, "matrix_room_id"),
            matrix_user_id=_required(ctx, "matrix_user_id"),
            digest_limit=digest_limit,
        )


def agentmail_api_key() -> str:
    value = os.environ.get("AGENTMAIL_API_KEY", "").strip()
    if not value:
        raise RuntimeError("AGENTMAIL_API_KEY is required")
    return value


def _required(ctx: ConfigContext, key: str) -> str:
    value = ctx.get_config(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"plugin setting {key!r} must be a non-empty string")
    return value.strip()


def _string(ctx: ConfigContext, key: str, default: str) -> str:
    value = ctx.get_config(key, default)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"plugin setting {key!r} must be a non-empty string")
    return value.strip()


def _integer(ctx: ConfigContext, key: str, default: int) -> int:
    value = ctx.get_config(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"plugin setting {key!r} must be an integer")
    return value
