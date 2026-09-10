"""Typed values stored by the inbox plugin."""

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum


@dataclass(frozen=True, slots=True)
class EmailContent:
    """The immutable structured content received for one email."""

    message_id: str
    thread_id: str | None
    subject: str
    sender: str
    recipients: tuple[str, ...]
    received_at: datetime
    text: str | None
    html: str | None
    readable_text: str


@dataclass(frozen=True, slots=True)
class Reference:
    """An exact external reference within an inbox namespace."""

    namespace: str
    kind: str
    value: str


@dataclass(frozen=True, slots=True)
class CardLocation:
    """The board and card associated with an external reference."""

    board_id: str
    card_id: str


class ProposalState(StrEnum):
    """The approval state of a proposed card action."""

    PENDING = "pending"
    APPROVING = "approving"
    APPROVED = "approved"
    DISMISSED = "dismissed"


class MessageDisposition(StrEnum):
    """The classification applied to a processed email."""

    IGNORED = "ignored"
    ASSOCIATED = "associated"
    PROPOSED = "proposed"


@dataclass(frozen=True, slots=True)
class Proposal:
    """A versioned proposal for an existing inactive triage card."""

    id: int
    version: int
    board_id: str
    card_id: str
    title: str
    body: str
    action_fingerprint: str
    state: ProposalState
    created_at: datetime


@dataclass(frozen=True, slots=True)
class DigestItem:
    """A reaction mapping captured when a digest was sent."""

    proposal_id: int
    proposal_version: int
    emoji: str


@dataclass(frozen=True, slots=True)
class QueuedMessage:
    """A webhook message claimed for full-content processing."""

    inbox_id: str
    message_id: str
    enqueued_at: datetime


@dataclass(frozen=True, slots=True)
class MessageOutcome:
    """The durable classification result for a processed email."""

    disposition: MessageDisposition
    reason: str
    location: CardLocation | None


@dataclass(frozen=True, slots=True)
class UpdateSummary:
    """A card update which has not necessarily appeared in a digest."""

    id: int
    board_id: str
    card_id: str
    inbox_id: str
    message_id: str
    summary: str
    created_at: datetime
