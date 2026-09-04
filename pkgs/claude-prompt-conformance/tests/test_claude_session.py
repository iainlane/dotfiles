from dataclasses import dataclass, field
from pathlib import Path

import msgspec
import pytest

from claude_prompt_conformance.claude_session import (
    ClaudeControlRecordDecodeError,
    ClaudeControlRequestUnsupportedError,
    ClaudeSdkSession,
)
from claude_prompt_conformance.models import (
    ClaudeBillingMode,
    ProcessExchange,
    ProcessOutputRecord,
    SecretFileDescriptor,
)


@dataclass
class RenewableIdentity:
    current: str
    replacement: str
    refreshes: list[tuple[str, float]] = field(default_factory=list)

    @property
    def billing_mode(self) -> ClaudeBillingMode:
        return ClaudeBillingMode.SUBSCRIPTION

    def environment(self, state: Path) -> dict[str, str]:
        return {"HOME": str(state)}

    def access_token(self) -> str:
        return self.current

    def refresh_access_token(self, rejected: str, deadline: float) -> str:
        if rejected != self.current:
            raise AssertionError((rejected, self.current))
        self.refreshes.append((rejected, deadline))
        self.current = self.replacement
        return self.current


@dataclass
class RecordingActivity:
    """Record the complete activity projection exposed by one SDK session."""

    events: list[tuple[str, str, str | int]] = field(default_factory=list)

    def start_activity(self, identifier: str, description: str) -> None:
        self.events.append(("started", identifier, description))

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None:
        self.events.append(("heartbeat", identifier, elapsed_seconds))

    def finish_activity(self, identifier: str, detail: str) -> None:
        self.events.append(("finished", identifier, detail))


def encoded(value: object) -> bytes:
    return msgspec.json.encode(value) + b"\n"


def received(value: object, received_at: float = 0) -> ProcessOutputRecord:
    return ProcessOutputRecord(encoded(value), received_at)


def decoded(values: tuple[bytes, ...]) -> tuple[object, ...]:
    return tuple(msgspec.json.decode(value) for value in values)


def test_claude_sdk_session_initialises_and_refreshes_oauth_structurally() -> None:
    identity = RenewableIdentity("initial-token", "refreshed-token")
    session = ClaudeSdkSession("Perform the repository task.", identity)

    initial = decoded(session.initial_input())
    secret = session.secret()
    refresh = session.receive(
        received(
            {
                "type": "control_request",
                "request_id": "refresh-17",
                "request": {"subtype": "oauth_token_refresh"},
            },
            10,
        )
    )

    assert (initial, secret, refresh, decoded(refresh.writes), identity) == (
        (
            {
                "type": "control_request",
                "request_id": "prompt-conformance-initialize",
                "request": {"subtype": "initialize", "hooks": None},
            },
            {
                "type": "user",
                "session_id": "",
                "message": {
                    "role": "user",
                    "content": "Perform the repository task.",
                },
                "parent_tool_use_id": None,
            },
        ),
        SecretFileDescriptor(
            "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
            b"initial-token",
        ),
        ProcessExchange(
            writes=(
                encoded(
                    {
                        "type": "control_response",
                        "response": {
                            "subtype": "success",
                            "request_id": "refresh-17",
                            "response": {"accessToken": "refreshed-token"},
                        },
                    }
                ),
            )
        ),
        (
            {
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": "refresh-17",
                    "response": {"accessToken": "refreshed-token"},
                },
            },
        ),
        RenewableIdentity(
            "refreshed-token",
            "refreshed-token",
            [("initial-token", 38)],
        ),
    )


def test_claude_sdk_session_coalesces_refreshes_emitted_before_completion() -> None:
    identity = RenewableIdentity("initial-token", "refreshed-token")
    session = ClaudeSdkSession("task", identity, monotonic=lambda: 20)
    requests = (
        received(
            {
                "type": "control_request",
                "request_id": "refresh-1",
                "request": {"subtype": "oauth_token_refresh"},
            },
            10,
        ),
        received(
            {
                "type": "control_request",
                "request_id": "refresh-2",
                "request": {"subtype": "oauth_token_refresh"},
            },
            15,
        ),
    )

    exchanges = tuple(session.receive(request) for request in requests)

    assert (
        tuple(decoded(exchange.writes) for exchange in exchanges),
        identity,
    ) == (
        (
            (
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": "refresh-1",
                        "response": {"accessToken": "refreshed-token"},
                    },
                },
            ),
            (
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": "refresh-2",
                        "response": {"accessToken": "refreshed-token"},
                    },
                },
            ),
        ),
        RenewableIdentity(
            "refreshed-token",
            "refreshed-token",
            [("initial-token", 38)],
        ),
    )


def test_claude_sdk_session_keeps_input_open_for_delegated_work() -> None:
    session = ClaudeSdkSession("task", RenewableIdentity("token", "replacement"))

    exchanges = tuple(
        session.receive(received(event))
        for event in (
            {
                "type": "system",
                "subtype": "task_started",
                "task_id": "worker-1",
                "task_type": "local_agent",
            },
            {"type": "result", "subtype": "success"},
            {
                "type": "system",
                "subtype": "task_updated",
                "task_id": "worker-1",
                "patch": {"status": "completed"},
            },
            {"type": "result", "subtype": "success"},
        )
    )

    assert exchanges == (
        ProcessExchange(),
        ProcessExchange(),
        ProcessExchange(),
        ProcessExchange(close_input=True),
    )


def test_claude_sdk_session_reports_actions_without_counting_heartbeats_as_work() -> (
    None
):
    activity = RecordingActivity()
    session = ClaudeSdkSession(
        "task",
        RenewableIdentity("token", "replacement"),
        activity=activity,
    )

    exchanges = tuple(
        session.receive(received(event))
        for event in (
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "tool-1",
                            "name": "Bash",
                            "input": {"description": "Run focused tests"},
                        }
                    ]
                },
            },
            {
                "type": "tool_progress",
                "parent_tool_use_id": "tool-1",
                "tool_name": "Bash",
                "elapsed_time_seconds": 125,
                "heartbeat": True,
            },
            {
                "type": "user",
                "message": {
                    "content": [{"type": "tool_result", "tool_use_id": "tool-1"}]
                },
            },
            {"type": "result", "subtype": "success"},
        )
    )

    assert (exchanges, activity) == (
        (
            ProcessExchange(),
            ProcessExchange(),
            ProcessExchange(),
            ProcessExchange(close_input=True),
        ),
        RecordingActivity(
            [
                ("started", "tool-1", "Bash: Run focused tests"),
                ("heartbeat", "tool-1", 125),
                ("finished", "tool-1", "Bash: Run focused tests finished"),
            ]
        ),
    )


def test_claude_sdk_session_retains_activity_across_a_provisional_result() -> None:
    activity = RecordingActivity()
    session = ClaudeSdkSession(
        "task",
        RenewableIdentity("token", "replacement"),
        activity=activity,
    )

    exchanges = tuple(
        session.receive(received(event))
        for event in (
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": "agent-1",
                            "name": "Agent",
                            "input": {"description": "Review the implementation"},
                        }
                    ]
                },
            },
            {
                "type": "system",
                "subtype": "task_started",
                "task_id": "task-1",
                "task_type": "local_agent",
            },
            {"type": "result", "subtype": "success"},
            {
                "type": "tool_progress",
                "parent_tool_use_id": "agent-1",
                "tool_name": "Agent",
                "elapsed_time_seconds": 60,
                "heartbeat": True,
            },
            {
                "type": "system",
                "subtype": "task_notification",
                "task_id": "task-1",
                "tool_use_id": "agent-1",
                "summary": "Review complete",
            },
        )
    )

    assert (exchanges, activity) == (
        (
            ProcessExchange(),
            ProcessExchange(),
            ProcessExchange(close_input=False),
            ProcessExchange(),
            ProcessExchange(),
        ),
        RecordingActivity(
            [
                ("started", "agent-1", "Agent: Review the implementation"),
                ("heartbeat", "agent-1", 60),
                ("finished", "agent-1", "Agent: Review the implementation finished"),
            ]
        ),
    )


def test_claude_sdk_session_rejects_an_unknown_control_request() -> None:
    session = ClaudeSdkSession("task", RenewableIdentity("token", "replacement"))

    with pytest.raises(ClaudeControlRequestUnsupportedError) as raised:
        session.receive(
            received(
                {
                    "type": "control_request",
                    "request_id": "request-1",
                    "request": {"subtype": "host_auth_token_refresh"},
                }
            )
        )

    assert raised.value == ClaudeControlRequestUnsupportedError(
        "host_auth_token_refresh"
    )


def test_claude_sdk_session_rejects_an_invalid_record() -> None:
    session = ClaudeSdkSession("task", RenewableIdentity("token", "replacement"))

    with pytest.raises(ClaudeControlRecordDecodeError) as raised:
        session.receive(ProcessOutputRecord(b"not json\n", 0))

    assert type(raised.value.cause) is msgspec.DecodeError


def test_claude_sdk_session_records_a_permission_denial_without_aborting() -> None:
    """A denial record carries a string message, unlike conversation records."""

    activity = RecordingActivity()
    session = ClaudeSdkSession(
        "task",
        RenewableIdentity("token", "replacement"),
        activity=activity,
    )

    exchange = session.receive(
        received(
            {
                "type": "system",
                "subtype": "permission_denied",
                "tool_name": "Bash",
                "tool_use_id": "toolu_01VLnJdWcebypjhZ1ZRWwAZs",
                "decision_reason_type": "safetyCheck",
                "decision_reason": "Dangerous rm operation on "
                "statically-unresolvable target",
                "message": "Dangerous rm operation detected: 'workspace/*'",
                "uuid": "1bbbff68-c22a-47a4-8c3c-0e76e7ba4424",
                "session_id": "560f086b-655f-4a92-be6b-56a450068d5c",
            }
        )
    )

    assert (exchange, activity) == (ProcessExchange(), RecordingActivity([]))


def test_claude_sdk_session_passes_unknown_record_kinds_by() -> None:
    session = ClaudeSdkSession("task", RenewableIdentity("token", "replacement"))

    exchange = session.receive(
        received({"type": "stream_event", "event": {"delta": "partial"}})
    )

    assert exchange == ProcessExchange()


def test_claude_sdk_session_still_rejects_a_malformed_conversation_record() -> None:
    session = ClaudeSdkSession("task", RenewableIdentity("token", "replacement"))

    with pytest.raises(ClaudeControlRecordDecodeError) as raised:
        session.receive(received({"type": "assistant", "message": "not an object"}))

    assert type(raised.value.cause) is msgspec.ValidationError
