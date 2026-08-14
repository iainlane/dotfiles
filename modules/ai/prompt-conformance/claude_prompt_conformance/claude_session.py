"""Bidirectional SDK control session for a Claude candidate process."""

import time
from collections.abc import Callable
from dataclasses import dataclass

import msgspec

from .errors import ConformanceError
from .models import ProcessExchange, ProcessOutputRecord, SecretFileDescriptor
from .ports import ActivityReporter, ClaudeIdentity
from .protocols.claude import (
    ClaudeAssistantRecord,
    ClaudeControlRequest,
    ClaudeControlRequestRecord,
    ClaudeControlResponse,
    ClaudeControlSuccess,
    ClaudeInitializeRequest,
    ClaudeOAuthTokenRefreshResult,
    ClaudeRecordKind,
    ClaudeResultRecord,
    ClaudeStreamRecord,
    ClaudeSystemRecord,
    ClaudeToolProgressRecord,
    ClaudeUserInput,
    ClaudeUserMessage,
    ClaudeUserRecord,
)


@dataclass(eq=True)
class ClaudeControlRecordDecodeError(ConformanceError):
    cause: Exception

    def __str__(self) -> str:
        return f"Claude emitted an invalid SDK control record: {self.cause}"


@dataclass(eq=True)
class ClaudeControlRequestIdMissingError(ConformanceError):
    def __str__(self) -> str:
        return "Claude's OAuth refresh request has no request identifier"


@dataclass(eq=True)
class ClaudeControlRequestBodyMissingError(ConformanceError):
    def __str__(self) -> str:
        return "Claude's SDK control request has no request body"


@dataclass(eq=True)
class ClaudeControlRequestUnsupportedError(ConformanceError):
    subtype: str

    def __str__(self) -> str:
        return f"Claude requested unsupported SDK control operation {self.subtype}"


def decode_stream_record(value: bytes) -> ClaudeStreamRecord | None:
    """Decode a record against its own schema, passing unknown kinds by."""

    try:
        kind = msgspec.json.decode(value, type=ClaudeRecordKind)
    except (msgspec.DecodeError, msgspec.ValidationError) as error:
        raise ClaudeControlRecordDecodeError(error) from error

    match kind.type:
        case "assistant":
            schema = ClaudeAssistantRecord
        case "user":
            schema = ClaudeUserRecord
        case "system":
            schema = ClaudeSystemRecord
        case "tool_progress":
            schema = ClaudeToolProgressRecord
        case "result":
            schema = ClaudeResultRecord
        case "control_request":
            schema = ClaudeControlRequestRecord
        case _:
            return None

    try:
        return msgspec.json.decode(value, type=schema)
    except (msgspec.DecodeError, msgspec.ValidationError) as error:
        raise ClaudeControlRecordDecodeError(error) from error


_INITIALIZE_REQUEST_ID = "prompt-conformance-initialize"
_DEFERRING_TASK_TYPES = frozenset({"local_agent", "local_workflow"})
_TERMINAL_TASK_STATUSES = frozenset({"completed", "failed", "stopped", "killed"})
_OAUTH_CALLBACK_BUDGET_SECONDS = 28


class ClaudeSdkSession:
    """Supply one task and answer OAuth refresh requests from Claude Code."""

    def __init__(
        self,
        task: str,
        identity: ClaudeIdentity,
        monotonic: Callable[[], float] = time.monotonic,
        activity: ActivityReporter | None = None,
    ) -> None:
        self._task = task
        self._identity = identity
        self._monotonic = monotonic
        self._activity = activity
        self._access_token = identity.access_token()
        self._inflight_tasks: set[str] = set()
        self._tool_activities: dict[str, str] = {}
        self._last_refresh_completed_at: float | None = None

    def secret(self) -> SecretFileDescriptor:
        """Expose the initial access token through Claude's descriptor contract."""

        return SecretFileDescriptor(
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
            self._access_token.encode(),
        )

    def initial_input(self) -> tuple[bytes, ...]:
        """Initialize the SDK protocol and submit the candidate task."""

        return (
            _line(
                ClaudeControlRequest(
                    request_id=_INITIALIZE_REQUEST_ID,
                    request=ClaudeInitializeRequest(),
                )
            ),
            _line(
                ClaudeUserInput(
                    session_id="",
                    message=ClaudeUserMessage(role="user", content=self._task),
                    parent_tool_use_id=None,
                )
            ),
        )

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        """Handle one Claude output record and return any protocol response."""

        event = self._decode(record)
        if event is None:
            return ProcessExchange()

        self._track_task(event)
        self._track_activity(event)
        if isinstance(event, ClaudeResultRecord):
            return ProcessExchange(close_input=not self._inflight_tasks)
        if not isinstance(event, ClaudeControlRequestRecord):
            return ProcessExchange()

        request = event.request
        if request is None:
            raise ClaudeControlRequestBodyMissingError
        if request.subtype != "oauth_token_refresh":
            raise ClaudeControlRequestUnsupportedError(request.subtype)
        if event.request_id is None:
            raise ClaudeControlRequestIdMissingError

        deadline = record.received_at + _OAUTH_CALLBACK_BUDGET_SECONDS
        if (
            self._last_refresh_completed_at is None
            or record.received_at > self._last_refresh_completed_at
        ):
            self._access_token = self._identity.refresh_access_token(
                self._access_token,
                deadline,
            )
            self._last_refresh_completed_at = self._monotonic()
        response = ClaudeControlResponse(
            ClaudeControlSuccess(
                request_id=event.request_id,
                response=ClaudeOAuthTokenRefreshResult(self._access_token),
            )
        )
        return ProcessExchange(writes=(_line(response),))

    def _decode(self, record: ProcessOutputRecord) -> ClaudeStreamRecord | None:
        return decode_stream_record(record.value)

    def _track_activity(self, event: ClaudeStreamRecord) -> None:
        activity = self._activity
        if activity is None:
            return

        match event:
            case ClaudeAssistantRecord() if event.message is not None:
                for block in event.message.content:
                    if block.type != "tool_use" or block.id is None:
                        continue
                    name = block.name or "Tool"
                    description = _tool_description(name, block.input)
                    self._tool_activities[block.id] = description
                    activity.start_activity(block.id, description)

            case ClaudeToolProgressRecord():
                tool_id = event.parent_tool_use_id
                if tool_id is not None and tool_id not in self._tool_activities:
                    self._tool_activities[tool_id] = event.tool_name or "Tool"
                    activity.start_activity(tool_id, self._tool_activities[tool_id])
                if tool_id is not None and event.elapsed_time_seconds is not None:
                    activity.heartbeat_activity(tool_id, event.elapsed_time_seconds)

            case ClaudeUserRecord() if event.message is not None:
                completed = tuple(
                    block.tool_use_id
                    for block in event.message.content
                    if block.type == "tool_result" and block.tool_use_id is not None
                )
                for tool_id in completed:
                    description = self._tool_activities.pop(tool_id, None)
                    if description is not None:
                        activity.finish_activity(tool_id, f"{description} finished")

            case ClaudeSystemRecord() if (
                event.subtype == "task_notification" and event.tool_use_id is not None
            ):
                description = self._tool_activities.pop(event.tool_use_id, None)
                if description is not None:
                    activity.finish_activity(
                        event.tool_use_id,
                        f"{description} finished",
                    )

            case ClaudeResultRecord() if not self._inflight_tasks:
                for tool_id, description in tuple(self._tool_activities.items()):
                    activity.finish_activity(tool_id, f"{description} finished")
                    del self._tool_activities[tool_id]

            case _:
                pass

    def _track_task(self, event: ClaudeStreamRecord) -> None:
        if not isinstance(event, ClaudeSystemRecord):
            return
        task_id = event.task_id
        if task_id is None:
            return
        if event.subtype == "task_started":
            if event.task_type in _DEFERRING_TASK_TYPES:
                self._inflight_tasks.add(task_id)
            return
        if event.subtype == "task_notification":
            self._inflight_tasks.discard(task_id)
            return
        if event.subtype != "task_updated" or event.patch is None:
            return
        if event.patch.status in _TERMINAL_TASK_STATUSES:
            self._inflight_tasks.discard(task_id)


def _line(value: msgspec.Struct) -> bytes:
    return msgspec.json.encode(value) + b"\n"


def _tool_description(name: str, value: object) -> str:
    if not isinstance(value, dict):
        return name

    description = value.get("description")
    if not isinstance(description, str) or not description.strip():
        return name
    return f"{name}: {description.strip()}"
