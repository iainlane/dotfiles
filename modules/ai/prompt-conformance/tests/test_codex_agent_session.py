from pathlib import Path

import msgspec
import pytest

from claude_prompt_conformance.codex_agent_session import (
    CodexAgentNotificationIdentityError,
    CodexAgentNotificationPhaseError,
    CodexAgentResponseMissingError,
    CodexAgentResponsePhaseError,
    CodexAgentSession,
    CodexTurnTerminalStatusError,
)
from claude_prompt_conformance.models import ProcessExchange, ProcessOutputRecord
from claude_prompt_conformance.protocols.codex_app_server import (
    CodexCompletedTurn,
    CodexTurnFailure,
)
from claude_prompt_conformance.protocols.codex_auth import CodexAccessCredential


class TransitioningIdentity:
    """Model an external identity whose refresh replaces its current access."""

    def __init__(self) -> None:
        self.current = CodexAccessCredential("old-access", "account-1", "pro")

    def authentication(self) -> CodexAccessCredential:
        return self.current

    def refresh(
        self,
        rejected_access_token: str,
        expected_account_id: str | None,
    ) -> CodexAccessCredential:
        if (rejected_access_token, expected_account_id) != (
            "old-access",
            "account-1",
        ):
            raise AssertionError("app-server supplied unexpected refresh context")
        self.current = CodexAccessCredential("new-access", "account-1", "pro")
        return self.current


def record(value: object) -> ProcessOutputRecord:
    return ProcessOutputRecord(msgspec.json.encode(value) + b"\n", 0.0)


def decoded(writes: tuple[bytes, ...]) -> tuple[object, ...]:
    return tuple(msgspec.json.decode(value) for value in writes)


def session(
    tmp_path: Path,
    identity: TransitioningIdentity | None = None,
) -> CodexAgentSession:
    root = tmp_path
    return CodexAgentSession(
        identity=identity if identity is not None else TransitioningIdentity(),
        transcript=root / "events.jsonl",
        cwd=root / "control",
        model="gpt-5.6-terra",
        effort="high",
        service_tier="fast",
        permission_profile="conformance_judge",
        prompt="Judge this work.\n",
        output_schema={"type": "object"},
    )


def advance_to_running(agent: CodexAgentSession, tmp_path: Path) -> None:
    """Drive the successful response prefix shared by terminal-state tests."""

    for value in (
        {
            "id": 1,
            "result": {
                "userAgent": "codex_cli_rs/0.146.0",
                "codexHome": str(tmp_path / "state"),
                "platformFamily": "unix",
                "platformOs": "macos",
            },
        },
        {"id": 2, "result": {"type": "chatgptAuthTokens"}},
        {"id": 3, "result": {"thread": {"id": "thread-1"}}},
        {"id": 4, "result": {"turn": {"id": "turn-1"}}},
    ):
        agent.receive(record(value))


def test_codex_agent_session_drives_external_auth_and_refresh(tmp_path) -> None:
    identity = TransitioningIdentity()
    agent = session(tmp_path, identity)
    exchanges = [decoded(agent.initial_input())]
    exchanges.append(
        decoded(
            agent.receive(
                record(
                    {
                        "id": 1,
                        "result": {
                            "userAgent": "codex_cli_rs/0.146.0",
                            "codexHome": str(tmp_path / "state"),
                            "platformFamily": "unix",
                            "platformOs": "macos",
                        },
                    }
                )
            ).writes
        )
    )
    exchanges.append(
        decoded(
            agent.receive(
                record({"id": 2, "result": {"type": "chatgptAuthTokens"}})
            ).writes
        )
    )
    exchanges.append(
        decoded(
            agent.receive(
                record(
                    {
                        "id": 91,
                        "method": "account/chatgptAuthTokens/refresh",
                        "params": {
                            "reason": "unauthorized",
                            "previousAccountId": "account-1",
                        },
                    }
                )
            ).writes
        )
    )
    exchanges.append(
        decoded(
            agent.receive(
                record({"id": 3, "result": {"thread": {"id": "thread-1"}}})
            ).writes
        )
    )
    exchanges.append(
        decoded(
            agent.receive(
                record({"id": 4, "result": {"turn": {"id": "turn-1"}}})
            ).writes
        )
    )
    exchanges.append(
        decoded(
            agent.receive(
                record(
                    {
                        "method": "item/completed",
                        "params": {
                            "threadId": "thread-1",
                            "turnId": "turn-1",
                            "item": {
                                "type": "agentMessage",
                                "id": "message-1",
                                "text": '{"summary":"sound"}',
                            },
                        },
                    }
                )
            ).writes
        )
    )
    terminal = agent.receive(
        record(
            {
                "method": "turn/completed",
                "params": {
                    "threadId": "thread-1",
                    "turn": {
                        "id": "turn-1",
                        "status": "completed",
                        "error": None,
                    },
                },
            }
        )
    )

    assert (
        exchanges,
        terminal,
        agent.response,
        identity.current,
    ) == (
        [
            (
                {
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {
                            "name": "prompt-conformance",
                            "title": "Prompt conformance",
                            "version": "1",
                        },
                        "capabilities": {"experimentalApi": True},
                    },
                },
            ),
            (
                {"method": "initialized", "params": {}},
                {
                    "id": 2,
                    "method": "account/login/start",
                    "params": {
                        "type": "chatgptAuthTokens",
                        "accessToken": "old-access",
                        "chatgptAccountId": "account-1",
                        "chatgptPlanType": "pro",
                    },
                },
            ),
            (
                {
                    "id": 3,
                    "method": "thread/start",
                    "params": {
                        "model": "gpt-5.6-terra",
                        "serviceTier": "fast",
                        "cwd": str(tmp_path / "control"),
                        "permissions": "conformance_judge",
                        "baseInstructions": "",
                        "developerInstructions": "",
                        "personality": "none",
                        "ephemeral": True,
                    },
                },
            ),
            (
                {
                    "id": 91,
                    "result": {
                        "accessToken": "new-access",
                        "chatgptAccountId": "account-1",
                        "chatgptPlanType": "pro",
                    },
                },
            ),
            (
                {
                    "id": 4,
                    "method": "turn/start",
                    "params": {
                        "threadId": "thread-1",
                        "input": [
                            {
                                "type": "text",
                                "text": "Judge this work.\n",
                                "textElements": [],
                            }
                        ],
                        "effort": "high",
                        "outputSchema": {"type": "object"},
                    },
                },
            ),
            (),
            (),
        ],
        ProcessExchange(close_input=True),
        '{"summary":"sound"}',
        CodexAccessCredential("new-access", "account-1", "pro"),
    )


@pytest.mark.parametrize(
    "turn",
    [
        CodexCompletedTurn(
            "turn-1",
            "failed",
            CodexTurnFailure("model failed"),
        ),
        CodexCompletedTurn(
            "turn-1",
            "interrupted",
            None,
        ),
    ],
)
def test_codex_agent_session_rejects_unsuccessful_terminal_outcomes(
    tmp_path,
    turn: CodexCompletedTurn,
) -> None:
    agent = session(tmp_path)
    advance_to_running(agent, tmp_path)

    with pytest.raises(CodexTurnTerminalStatusError) as raised:
        agent.receive(
            record(
                {
                    "method": "turn/completed",
                    "params": {
                        "threadId": "thread-1",
                        "turn": msgspec.to_builtins(turn),
                    },
                }
            )
        )

    assert raised.value == CodexTurnTerminalStatusError(turn)


def test_codex_agent_session_requires_an_assistant_response(tmp_path: Path) -> None:
    agent = session(tmp_path)
    advance_to_running(agent, tmp_path)

    with pytest.raises(CodexAgentResponseMissingError) as raised:
        agent.receive(
            record(
                {
                    "method": "turn/completed",
                    "params": {
                        "threadId": "thread-1",
                        "turn": {
                            "id": "turn-1",
                            "status": "completed",
                            "error": None,
                        },
                    },
                }
            )
        )

    assert raised.value == CodexAgentResponseMissingError(tmp_path / "events.jsonl")


def test_codex_agent_session_rejects_model_evidence_before_a_turn_runs(
    tmp_path: Path,
) -> None:
    agent = session(tmp_path)

    with pytest.raises(CodexAgentNotificationPhaseError) as raised:
        agent.receive(
            record(
                {
                    "method": "item/completed",
                    "params": {
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "item": {
                            "type": "agentMessage",
                            "id": "message-1",
                            "text": "untrusted",
                        },
                    },
                }
            )
        )

    assert raised.value == CodexAgentNotificationPhaseError(
        "item/completed",
        "initializing",
    )


def test_codex_agent_session_rejects_a_duplicate_turn_start_response(
    tmp_path: Path,
) -> None:
    agent = session(tmp_path)
    advance_to_running(agent, tmp_path)

    with pytest.raises(CodexAgentResponsePhaseError) as raised:
        agent.receive(record({"id": 4, "result": {"turn": {"id": "other-turn"}}}))

    assert raised.value == CodexAgentResponsePhaseError(
        4,
        "starting a turn",
        "running a turn",
    )


@pytest.mark.parametrize(
    ("method", "params"),
    [
        (
            "item/completed",
            {
                "threadId": "other-thread",
                "turnId": "turn-1",
                "item": {
                    "type": "agentMessage",
                    "id": "message-1",
                    "text": "untrusted",
                },
            },
        ),
        (
            "turn/completed",
            {
                "threadId": "thread-1",
                "turn": {
                    "id": "other-turn",
                    "status": "completed",
                    "error": None,
                },
            },
        ),
    ],
)
def test_codex_agent_session_rejects_evidence_from_another_turn(
    tmp_path: Path,
    method: str,
    params: dict[str, object],
) -> None:
    agent = session(tmp_path)
    advance_to_running(agent, tmp_path)

    with pytest.raises(CodexAgentNotificationIdentityError) as raised:
        agent.receive(record({"method": method, "params": params}))

    expected = (
        CodexAgentNotificationIdentityError(
            method,
            "thread-1",
            "other-thread",
            "turn-1",
            "turn-1",
        )
        if method == "item/completed"
        else CodexAgentNotificationIdentityError(
            method,
            "thread-1",
            "thread-1",
            "turn-1",
            "other-turn",
        )
    )
    assert raised.value == expected
