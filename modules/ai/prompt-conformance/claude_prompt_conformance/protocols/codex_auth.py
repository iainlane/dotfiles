"""Typed representations of Codex subscription authentication."""

from typing import Literal

import msgspec


class CodexTokenData(msgspec.Struct, frozen=True):
    """Validated subscription tokens retained by the run-scoped broker."""

    id_token: str
    access_token: str
    refresh_token: str
    account_id: str


class CodexStoredTokenData(msgspec.Struct, frozen=True):
    """Potentially incomplete token fields read at the credential boundary."""

    id_token: str
    access_token: str
    refresh_token: str
    account_id: str | None = None


class CodexHostCredentialProjection(msgspec.Struct, frozen=True):
    """Known fields projected from a potentially newer host credential."""

    tokens: CodexStoredTokenData | None = None
    last_refresh: str | None = None


class CodexAccessCredential(msgspec.Struct, frozen=True):
    """Non-refreshable authentication supplied to one Codex app-server."""

    access_token: str
    account_id: str
    plan_type: str | None = None


class CodexOAuthRefreshRequest(msgspec.Struct, frozen=True):
    """OAuth refresh request understood by Codex's token authority."""

    client_id: str
    grant_type: Literal["refresh_token"]
    refresh_token: str


class CodexOAuthRefreshResponse(msgspec.Struct, frozen=True):
    """Tokens returned by Codex's OAuth refresh endpoint."""

    id_token: str | None = None
    access_token: str | None = None
    refresh_token: str | None = None


class CodexOAuthNestedFailure(msgspec.Struct, frozen=True):
    """Nested OAuth failure returned by the Codex token authority."""

    code: str
    message: str | None = None


class CodexOAuthNestedFailureDocument(msgspec.Struct, frozen=True):
    """Envelope around a structured Codex OAuth failure."""

    error: CodexOAuthNestedFailure


class CodexOAuthFlatFailureDocument(msgspec.Struct, frozen=True):
    """OAuth failure using the standard string-valued error shape."""

    error: str
    error_description: str | None = None


class CodexOAuthFailure(msgspec.Struct, frozen=True):
    """Normalized OAuth failure retained by typed boundary errors."""

    code: str | None
    description: str | None


class CodexAppServerRefreshParameters(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    forbid_unknown_fields=True,
):
    """Refresh context sent from app-server to its external-auth client."""

    reason: Literal["unauthorized"]
    previous_account_id: str | None


class CodexAppServerRefreshResult(
    msgspec.Struct,
    frozen=True,
    rename="camel",
):
    """Fresh external authentication returned to Codex app-server."""

    access_token: str
    chatgpt_account_id: str
    chatgpt_plan_type: str | None
