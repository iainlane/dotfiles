"""Schemas emitted by Claude and retained as canonical candidate actions."""

from typing import Any

import msgspec


class ClaudeContent(msgspec.Struct, frozen=True):
    type: str
    id: str | None = None
    name: str | None = None
    input: Any = None
    tool_use_id: str | None = None
    content: Any = None
    is_error: bool = False


class ClaudeMessage(msgspec.Struct, frozen=True):
    content: tuple[ClaudeContent, ...] = ()


class ClaudeEvent(msgspec.Struct, frozen=True):
    type: str
    subtype: str | None = None
    output_style: str | None = None
    model: str | None = None
    is_error: bool = False
    result: str | None = None
    errors: tuple[str, ...] = ()
    terminal_reason: str | None = None
    # A system record's message is human-readable text; conversation records
    # carry content blocks.
    message: ClaudeMessage | str | None = None


class ClaudeOAuth(msgspec.Struct, frozen=True, rename="camel"):
    access_token: str = msgspec.field(name="accessToken")
    refresh_token: str = msgspec.field(name="refreshToken")
    expires_at: int = msgspec.field(name="expiresAt")
    refresh_token_expires_at: int | None = msgspec.field(
        default=None,
        name="refreshTokenExpiresAt",
    )
    scopes: tuple[str, ...] = ()
    client_id: str | None = None
    subscription_type: str | None = None
    rate_limit_tier: str | None = None


class ClaudeCredentialInput(msgspec.Struct, frozen=True):
    oauth: ClaudeOAuth = msgspec.field(name="claudeAiOauth")


class ClaudeOAuthRefreshResponse(msgspec.Struct, frozen=True):
    access_token: str
    expires_in: int
    refresh_token: str | None = None
    refresh_token_expires_in: int | None = None
    scope: str | None = None


class ClaudeOAuthErrorResponse(msgspec.Struct, frozen=True):
    error: str | None = None
    error_description: str | None = None


class ClaudeInitializeRequest(
    msgspec.Struct,
    frozen=True,
    tag="initialize",
    tag_field="subtype",
    rename="camel",
):
    hooks: None = None


class ClaudeOAuthTokenRefreshRequest(
    msgspec.Struct,
    frozen=True,
    tag="oauth_token_refresh",
    tag_field="subtype",
):
    pass


ClaudeControlRequestBody = ClaudeInitializeRequest | ClaudeOAuthTokenRefreshRequest


class ClaudeControlRequest(msgspec.Struct, frozen=True, tag="control_request"):
    request_id: str
    request: ClaudeControlRequestBody


class ClaudeUserMessage(msgspec.Struct, frozen=True):
    role: str
    content: str


class ClaudeUserInput(msgspec.Struct, frozen=True, tag="user"):
    session_id: str
    message: ClaudeUserMessage
    parent_tool_use_id: str | None


class ClaudeOAuthTokenRefreshResult(msgspec.Struct, frozen=True, rename="camel"):
    access_token: str


class ClaudeControlSuccess(
    msgspec.Struct,
    frozen=True,
    tag="success",
    tag_field="subtype",
):
    request_id: str
    response: ClaudeOAuthTokenRefreshResult


class ClaudeControlResponse(msgspec.Struct, frozen=True, tag="control_response"):
    response: ClaudeControlSuccess


class ClaudeTaskPatch(msgspec.Struct, frozen=True):
    status: str | None = None


class ClaudeRequestKind(msgspec.Struct, frozen=True):
    subtype: str


class ClaudeRecordKind(msgspec.Struct, frozen=True):
    """The discriminator read before choosing a record's own schema."""

    type: str


class ClaudeAssistantRecord(
    msgspec.Struct,
    frozen=True,
    tag="assistant",
    tag_field="type",
):
    message: ClaudeMessage | None = None


class ClaudeUserRecord(msgspec.Struct, frozen=True, tag="user", tag_field="type"):
    message: ClaudeMessage | None = None


class ClaudeSystemRecord(msgspec.Struct, frozen=True, tag="system", tag_field="type"):
    """A client-side notification, such as a task event or a tool denial.

    Unlike conversation records, a system record's `message` is human-readable
    text (for example the explanation on a `permission_denied` record).
    """

    subtype: str | None = None
    message: str | None = None
    task_id: str | None = None
    task_type: str | None = None
    patch: ClaudeTaskPatch | None = None
    tool_use_id: str | None = None
    summary: str | None = None


class ClaudeToolProgressRecord(
    msgspec.Struct,
    frozen=True,
    tag="tool_progress",
    tag_field="type",
):
    parent_tool_use_id: str | None = None
    tool_name: str | None = None
    elapsed_time_seconds: int | None = None
    heartbeat: bool = False


class ClaudeResultRecord(msgspec.Struct, frozen=True, tag="result", tag_field="type"):
    subtype: str | None = None
    is_error: bool = False


class ClaudeControlRequestRecord(
    msgspec.Struct,
    frozen=True,
    tag="control_request",
    tag_field="type",
):
    request_id: str | None = None
    request: ClaudeRequestKind | None = None


ClaudeStreamRecord = (
    ClaudeAssistantRecord
    | ClaudeUserRecord
    | ClaudeSystemRecord
    | ClaudeToolProgressRecord
    | ClaudeResultRecord
    | ClaudeControlRequestRecord
)


class CandidateToolUse(
    msgspec.Struct,
    frozen=True,
    tag="tool_use",
    tag_field="type",
):
    id: str | None
    name: str | None
    input: Any


class CandidateToolResult(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    tag="tool_result",
    tag_field="type",
):
    tool_use_id: str | None
    content: Any
    is_error: bool


CandidateAction = CandidateToolUse | CandidateToolResult
