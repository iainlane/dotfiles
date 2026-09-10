from dataclasses import dataclass, field
from datetime import UTC, datetime
from importlib import import_module
from typing import Any

import pytest

from hermes_inbox.agentmail import AgentMailSource


@dataclass
class Message:
    inbox_id: str = "inbox"
    message_id: str = "message"
    thread_id: str | None = "thread"
    subject: str | None = "Subject"
    from_: str = "Alice <alice@example.com>"
    to: list[str] = field(default_factory=lambda: ["work@example.com"])
    timestamp: datetime | str = datetime(2026, 1, 2, tzinfo=UTC)
    text: str | None = None
    html: str | None = "<p>Complete <strong>message</strong></p>"


class Messages:
    def get(self, *, inbox_id: str, message_id: str) -> Message:
        return Message(inbox_id=inbox_id, message_id=message_id)


def test_fetch_preserves_all_senders_and_full_html() -> None:
    result = AgentMailSource(Messages()).fetch("inbox", "message")

    assert result.sender == "Alice <alice@example.com>"
    assert result.html == "<p>Complete <strong>message</strong></p>"
    assert result.readable_text == "Complete **message**"


def test_real_sdk_message_contract_uses_string_sender() -> None:
    agentmail = pytest.importorskip("agentmail")
    httpx = import_module("httpx")

    def respond(request: Any) -> Any:
        assert "/v0/inboxes/inbox/messages/message" in str(request.url)
        return httpx.Response(
            200,
            json={
                "inbox_id": "inbox",
                "thread_id": "thread",
                "message_id": "message",
                "labels": ["received"],
                "timestamp": "2026-01-02T00:00:00Z",
                "from": "Alice <alice@example.com>",
                "to": ["work@example.com"],
                "subject": "Subject",
                "text": "Complete message",
                "html": "<p>Complete message</p>",
                "size": 16,
                "created_at": "2026-01-02T00:00:00Z",
                "updated_at": "2026-01-02T00:00:00Z",
            },
        )

    client = agentmail.AgentMail(
        api_key="test-key",
        httpx_client=httpx.Client(transport=httpx.MockTransport(respond)),
    )

    result = AgentMailSource(client.inboxes.messages).fetch("inbox", "message")

    assert result.sender == "Alice <alice@example.com>"
    assert result.recipients == ("work@example.com",)
    assert result.text == "Complete message"
    assert result.html == "<p>Complete message</p>"
