from __future__ import annotations

from datetime import datetime
from importlib import import_module
from typing import Protocol

from .content import normalise_email
from .models import EmailContent


class MessageResource(Protocol):
    def get(self, *, inbox_id: str, message_id: str) -> AgentMailMessage: ...


class AgentMailMessage(Protocol):
    inbox_id: str
    message_id: str
    thread_id: str | None
    subject: str | None
    from_: str
    to: list[str]
    timestamp: datetime | str
    text: str | None
    html: str | None


class AgentMailSource:
    def __init__(self, messages: MessageResource) -> None:
        self._messages = messages

    @classmethod
    def from_api_key(cls, api_key: str) -> AgentMailSource:
        client = import_module("agentmail").AgentMail(api_key=api_key)
        return cls(client.inboxes.messages)

    def fetch(self, inbox_id: str, message_id: str) -> EmailContent:
        message = self._messages.get(inbox_id=inbox_id, message_id=message_id)
        if message.inbox_id != inbox_id or message.message_id != message_id:
            raise ValueError("AgentMail returned a different message")
        if not message.from_.strip():
            raise ValueError("AgentMail message has no sender")
        received_at = message.timestamp
        if isinstance(received_at, str):
            received_at = datetime.fromisoformat(received_at)
        return normalise_email(
            message_id=message.message_id,
            thread_id=message.thread_id,
            subject=message.subject or "(no subject)",
            sender=message.from_,
            recipients=tuple(message.to),
            received_at=received_at,
            text=message.text,
            html=message.html,
        )
