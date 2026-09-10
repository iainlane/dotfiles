"""SQLite persistence for durable inbox processing and approvals."""

import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path

from hermes_inbox.content import action_fingerprint
from hermes_inbox.models import (
    CardLocation,
    DigestItem,
    EmailContent,
    MessageDisposition,
    MessageOutcome,
    Proposal,
    ProposalState,
    QueuedMessage,
    Reference,
    UpdateSummary,
)

_SCHEMA_VERSION = 1


class InboxStore:
    """Store inbox state in a SQLite database at ``path``."""

    def __init__(self, path: Path) -> None:
        self._path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self._migrate()

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self._path, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        try:
            yield connection
        finally:
            connection.close()

    @contextmanager
    def _write(self) -> Iterator[sqlite3.Connection]:
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
            except BaseException:
                connection.rollback()
                raise
            connection.commit()

    def _migrate(self) -> None:
        with self._write() as connection:
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version > _SCHEMA_VERSION:
                msg = (
                    f"database schema version {version} is newer than {_SCHEMA_VERSION}"
                )
                raise RuntimeError(msg)
            if version == _SCHEMA_VERSION:
                return

            statements = """
                CREATE TABLE message_queue (
                    inbox_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('pending', 'processing', 'done', 'failed')
                    ),
                    enqueued_at TEXT NOT NULL,
                    lease_expires_at TEXT,
                    failure_reason TEXT,
                    PRIMARY KEY (inbox_id, message_id)
                );
                CREATE INDEX message_queue_pending
                    ON message_queue (state, enqueued_at, inbox_id, message_id);

                CREATE TABLE email_content (
                    inbox_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    thread_id TEXT,
                    subject TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    recipients_json TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    text_body TEXT,
                    html_body TEXT,
                    readable_text TEXT NOT NULL,
                    disposition TEXT NOT NULL CHECK (
                        disposition IN ('ignored', 'associated', 'proposed')
                    ),
                    reason TEXT NOT NULL,
                    board_id TEXT,
                    card_id TEXT,
                    PRIMARY KEY (inbox_id, message_id),
                    FOREIGN KEY (inbox_id, message_id)
                        REFERENCES message_queue (inbox_id, message_id)
                );

                CREATE TABLE card_references (
                    namespace TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    value TEXT NOT NULL,
                    board_id TEXT NOT NULL,
                    card_id TEXT NOT NULL,
                    PRIMARY KEY (namespace, kind, value, board_id, card_id)
                );
                CREATE INDEX card_references_lookup
                    ON card_references (namespace, kind, value);

                CREATE TABLE proposals (
                    id INTEGER PRIMARY KEY,
                    version INTEGER NOT NULL,
                    board_id TEXT NOT NULL,
                    card_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    action_fingerprint TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('pending', 'approving', 'approved', 'dismissed')
                    ),
                    created_at TEXT NOT NULL,
                    last_shown_at TEXT,
                    UNIQUE (board_id, card_id)
                );
                CREATE INDEX proposals_digest_order
                    ON proposals (state, last_shown_at, created_at, id);

                CREATE TABLE digest_items (
                    room_id TEXT NOT NULL,
                    event_id TEXT NOT NULL,
                    emoji TEXT NOT NULL,
                    proposal_id INTEGER NOT NULL,
                    proposal_version INTEGER NOT NULL,
                    PRIMARY KEY (room_id, event_id, emoji),
                    FOREIGN KEY (proposal_id) REFERENCES proposals (id)
                );

                CREATE TABLE update_summaries (
                    id INTEGER PRIMARY KEY,
                    board_id TEXT NOT NULL,
                    card_id TEXT NOT NULL,
                    inbox_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    reported_room_id TEXT,
                    reported_event_id TEXT,
                    UNIQUE (board_id, card_id, inbox_id, message_id)
                );
                CREATE INDEX update_summaries_unreported
                    ON update_summaries (reported_event_id, created_at, id);
                """
            for statement in statements.split(";"):
                if statement.strip():
                    connection.execute(statement)
            connection.execute(f"PRAGMA user_version = {_SCHEMA_VERSION}")

    def enqueue_message(
        self,
        inbox_id: str,
        message_id: str,
        *,
        now: datetime | None = None,
    ) -> bool:
        """Add a verified webhook message to the durable work queue."""
        enqueued_at = _timestamp(now)
        with self._write() as connection:
            cursor = connection.execute(
                """
                INSERT OR IGNORE INTO message_queue
                    (inbox_id, message_id, state, enqueued_at)
                VALUES (?, ?, 'pending', ?)
                """,
                (inbox_id, message_id, enqueued_at),
            )
        return cursor.rowcount == 1

    def claim_message(
        self,
        *,
        now: datetime | None = None,
        lease_for: timedelta = timedelta(minutes=5),
    ) -> QueuedMessage | None:
        """Claim the oldest available message, including an expired claim."""
        claimed_at = now or datetime.now(tz=UTC)
        lease_expires_at = claimed_at + lease_for
        with self._write() as connection:
            row = connection.execute(
                """
                SELECT inbox_id, message_id, enqueued_at
                FROM message_queue
                WHERE state = 'pending'
                   OR (state = 'processing' AND lease_expires_at <= ?)
                ORDER BY enqueued_at, inbox_id, message_id
                LIMIT 1
                """,
                (_timestamp(claimed_at),),
            ).fetchone()
            if row is None:
                return None
            connection.execute(
                """
                UPDATE message_queue
                SET state = 'processing', lease_expires_at = ?
                WHERE inbox_id = ? AND message_id = ?
                """,
                (_timestamp(lease_expires_at), row["inbox_id"], row["message_id"]),
            )
        return QueuedMessage(
            inbox_id=row["inbox_id"],
            message_id=row["message_id"],
            enqueued_at=datetime.fromisoformat(row["enqueued_at"]),
        )

    def release_message(self, inbox_id: str, message_id: str) -> None:
        """Return a claimed message to the pending queue after a failed attempt."""
        with self._write() as connection:
            connection.execute(
                """
                UPDATE message_queue
                SET state = 'pending', lease_expires_at = NULL
                WHERE inbox_id = ? AND message_id = ? AND state = 'processing'
                """,
                (inbox_id, message_id),
            )

    def fail_message(self, inbox_id: str, message_id: str, reason: str) -> None:
        """Terminally fail a claimed poison message so later work can proceed."""
        with self._write() as connection:
            cursor = connection.execute(
                """
                UPDATE message_queue
                SET state = 'failed', lease_expires_at = NULL, failure_reason = ?
                WHERE inbox_id = ? AND message_id = ? AND state = 'processing'
                """,
                (reason, inbox_id, message_id),
            )
            if cursor.rowcount != 1:
                msg = f"message {inbox_id}/{message_id} is not claimed"
                raise ValueError(msg)

    def complete_message(
        self,
        inbox_id: str,
        content: EmailContent,
        *,
        disposition: MessageDisposition,
        reason: str,
        location: CardLocation | None = None,
    ) -> None:
        """Store fetched content and mark its queue item as done atomically."""
        if (disposition is MessageDisposition.IGNORED) == (location is not None):
            msg = (
                "ignored messages must omit a card location; other outcomes require one"
            )
            raise ValueError(msg)
        with self._write() as connection:
            cursor = connection.execute(
                """
                UPDATE message_queue
                SET state = 'done', lease_expires_at = NULL
                WHERE inbox_id = ? AND message_id = ? AND state = 'processing'
                """,
                (inbox_id, content.message_id),
            )
            if cursor.rowcount != 1:
                msg = f"message {inbox_id}/{content.message_id} is not claimed"
                raise ValueError(msg)
            connection.execute(
                """
                INSERT INTO email_content VALUES (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                )
                ON CONFLICT (inbox_id, message_id) DO UPDATE SET
                    thread_id = excluded.thread_id,
                    subject = excluded.subject,
                    sender = excluded.sender,
                    recipients_json = excluded.recipients_json,
                    received_at = excluded.received_at,
                    text_body = excluded.text_body,
                    html_body = excluded.html_body,
                    readable_text = excluded.readable_text,
                    disposition = excluded.disposition,
                    reason = excluded.reason,
                    board_id = excluded.board_id,
                    card_id = excluded.card_id
                """,
                (
                    inbox_id,
                    content.message_id,
                    content.thread_id,
                    content.subject,
                    content.sender,
                    json.dumps(content.recipients),
                    content.received_at.isoformat(),
                    content.text,
                    content.html,
                    content.readable_text,
                    disposition,
                    reason,
                    None if location is None else location.board_id,
                    None if location is None else location.card_id,
                ),
            )

    def get_message(self, inbox_id: str, message_id: str) -> EmailContent | None:
        """Return the full fetched content for a completed message."""
        with self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM email_content WHERE inbox_id = ? AND message_id = ?",
                (inbox_id, message_id),
            ).fetchone()
        return None if row is None else _email(row)

    def get_message_outcome(
        self, inbox_id: str, message_id: str
    ) -> MessageOutcome | None:
        """Return the recorded classification for a completed message."""
        with self._connection() as connection:
            row = connection.execute(
                """
                SELECT disposition, reason, board_id, card_id
                FROM email_content WHERE inbox_id = ? AND message_id = ?
                """,
                (inbox_id, message_id),
            ).fetchone()
        if row is None:
            return None
        location = None
        if row["board_id"] is not None and row["card_id"] is not None:
            location = CardLocation(row["board_id"], row["card_id"])
        return MessageOutcome(
            MessageDisposition(row["disposition"]), row["reason"], location
        )

    def add_reference(self, location: CardLocation, reference: Reference) -> None:
        """Associate an exact external reference with a card."""
        with self._write() as connection:
            connection.execute(
                "INSERT OR IGNORE INTO card_references VALUES (?, ?, ?, ?, ?)",
                (*_reference_values(reference), location.board_id, location.card_id),
            )

    def find_reference(self, reference: Reference) -> tuple[CardLocation, ...]:
        """Return every card associated with an exact reference."""
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT board_id, card_id FROM card_references
                WHERE namespace = ? AND kind = ? AND value = ?
                ORDER BY rowid
                """,
                _reference_values(reference),
            ).fetchall()
        return tuple(CardLocation(row["board_id"], row["card_id"]) for row in rows)

    def create_proposal(
        self,
        board_id: str,
        card_id: str,
        title: str,
        body: str,
        *,
        now: datetime | None = None,
    ) -> Proposal:
        """Create a pending proposal for the exact card contents."""
        created_at = _timestamp(now)
        fingerprint = action_fingerprint(title, body)
        with self._write() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO proposals
                    (version, board_id, card_id, title, body, action_fingerprint,
                     state, created_at)
                VALUES (1, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                (board_id, card_id, title, body, fingerprint, created_at),
            )
            row = connection.execute(
                "SELECT * FROM proposals WHERE board_id = ? AND card_id = ?",
                (board_id, card_id),
            ).fetchone()
        return _proposal(row)

    def update_proposal(self, proposal_id: int, title: str, body: str) -> Proposal:
        """Replace a pending proposal and invalidate its earlier digest entries."""
        with self._write() as connection:
            cursor = connection.execute(
                """
                UPDATE proposals
                SET version = version + 1, title = ?, body = ?,
                    action_fingerprint = ?, last_shown_at = NULL
                WHERE id = ? AND state = 'pending'
                """,
                (title, body, action_fingerprint(title, body), proposal_id),
            )
            if cursor.rowcount != 1:
                raise ValueError("proposal is not pending")
            row = connection.execute(
                "SELECT * FROM proposals WHERE id = ?", (proposal_id,)
            ).fetchone()
        return _proposal(row)

    def dismiss_proposal(self, proposal_id: int) -> bool:
        """Dismiss a pending proposal."""
        with self._write() as connection:
            cursor = connection.execute(
                "UPDATE proposals SET state = 'dismissed' WHERE id = ? AND state = 'pending'",
                (proposal_id,),
            )
        return cursor.rowcount == 1

    def pending_for_digest(self, *, limit: int = 10) -> tuple[Proposal, ...]:
        """Return pending proposals, preferring those never shown in a digest."""
        if not 1 <= limit <= 10:
            raise ValueError("digest limit must be between 1 and 10")
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT * FROM proposals WHERE state = 'pending'
                ORDER BY last_shown_at IS NOT NULL, last_shown_at, created_at, id
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return tuple(_proposal(row) for row in rows)

    def record_digest(
        self,
        room_id: str,
        event_id: str,
        items: tuple[DigestItem, ...],
        *,
        now: datetime | None = None,
    ) -> None:
        """Record the exact reaction mapping after a digest was delivered."""
        if len(items) > 10:
            raise ValueError("a digest can contain at most 10 proposals")
        shown_at = _timestamp(now)
        with self._write() as connection:
            for item in items:
                row = connection.execute(
                    "SELECT version, state FROM proposals WHERE id = ?",
                    (item.proposal_id,),
                ).fetchone()
                if (
                    row is None
                    or row["version"] != item.proposal_version
                    or row["state"] != ProposalState.PENDING
                ):
                    raise ValueError(
                        "digest item does not identify a pending proposal version"
                    )
                connection.execute(
                    "INSERT INTO digest_items VALUES (?, ?, ?, ?, ?)",
                    (
                        room_id,
                        event_id,
                        item.emoji,
                        item.proposal_id,
                        item.proposal_version,
                    ),
                )
                connection.execute(
                    "UPDATE proposals SET last_shown_at = ? WHERE id = ?",
                    (shown_at, item.proposal_id),
                )

    def resolve_digest_action(
        self, room_id: str, event_id: str, emoji: str
    ) -> Proposal | None:
        """Resolve a reaction only while its exact proposal version is pending."""
        with self._connection() as connection:
            row = connection.execute(
                """
                SELECT p.* FROM digest_items AS d
                JOIN proposals AS p ON p.id = d.proposal_id
                WHERE d.room_id = ? AND d.event_id = ? AND d.emoji = ?
                  AND p.version = d.proposal_version AND p.state = 'pending'
                """,
                (room_id, event_id, emoji),
            ).fetchone()
        return None if row is None else _proposal(row)

    def claim_digest_approval(
        self, room_id: str, event_id: str, emoji: str
    ) -> Proposal | None:
        """Reserve the exact pending proposal mapped to a reaction."""
        with self._write() as connection:
            row = connection.execute(
                """
                SELECT p.id FROM digest_items AS d
                JOIN proposals AS p ON p.id = d.proposal_id
                WHERE d.room_id = ? AND d.event_id = ? AND d.emoji = ?
                  AND p.version = d.proposal_version AND p.state = 'pending'
                """,
                (room_id, event_id, emoji),
            ).fetchone()
            if row is None:
                return None
            connection.execute(
                "UPDATE proposals SET state = 'approving' WHERE id = ? AND state = 'pending'",
                (row["id"],),
            )
            claimed = connection.execute(
                "SELECT * FROM proposals WHERE id = ?", (row["id"],)
            ).fetchone()
        return _proposal(claimed)

    def finalise_digest_approval(self, proposal_id: int, *, succeeded: bool) -> bool:
        """Approve a successful reservation or dismiss one whose card changed."""
        state = ProposalState.APPROVED if succeeded else ProposalState.DISMISSED
        with self._write() as connection:
            cursor = connection.execute(
                """
                UPDATE proposals SET state = ?
                WHERE id = ? AND state = 'approving'
                """,
                (state, proposal_id),
            )
        return cursor.rowcount == 1

    def record_card_update(
        self,
        location: CardLocation,
        inbox_id: str,
        message_id: str,
        summary: str,
        *,
        now: datetime | None = None,
    ) -> UpdateSummary:
        """Record a card update for a later progress digest."""
        created_at = _timestamp(now)
        with self._write() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO update_summaries
                    (board_id, card_id, inbox_id, message_id, summary, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    location.board_id,
                    location.card_id,
                    inbox_id,
                    message_id,
                    summary,
                    created_at,
                ),
            )
            row = connection.execute(
                """
                SELECT * FROM update_summaries
                WHERE board_id = ? AND card_id = ?
                  AND inbox_id = ? AND message_id = ?
                """,
                (location.board_id, location.card_id, inbox_id, message_id),
            ).fetchone()
        return _update(row)

    def list_unreported_updates(self, *, limit: int = 10) -> tuple[UpdateSummary, ...]:
        """Return the oldest card updates which have not appeared in a digest."""
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT * FROM update_summaries WHERE reported_event_id IS NULL
                ORDER BY created_at, id LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return tuple(_update(row) for row in rows)

    def mark_updates_reported(
        self, update_ids: tuple[int, ...], room_id: str, event_id: str
    ) -> None:
        """Mark card updates reported after their Matrix digest was delivered."""
        with self._write() as connection:
            connection.executemany(
                """
                UPDATE update_summaries
                SET reported_room_id = ?, reported_event_id = ?
                WHERE id = ? AND reported_event_id IS NULL
                """,
                ((room_id, event_id, update_id) for update_id in update_ids),
            )


def _timestamp(value: datetime | None) -> str:
    timestamp = value or datetime.now(tz=UTC)
    if timestamp.tzinfo is None:
        raise ValueError("timestamps must include a UTC offset")
    return timestamp.astimezone(UTC).isoformat()


def _reference_values(reference: Reference) -> tuple[str, str, str]:
    return reference.namespace, reference.kind, reference.value


def _email(row: sqlite3.Row) -> EmailContent:
    recipients = tuple(json.loads(row["recipients_json"]))
    return EmailContent(
        message_id=row["message_id"],
        thread_id=row["thread_id"],
        subject=row["subject"],
        sender=row["sender"],
        recipients=recipients,
        received_at=datetime.fromisoformat(row["received_at"]),
        text=row["text_body"],
        html=row["html_body"],
        readable_text=row["readable_text"],
    )


def _proposal(row: sqlite3.Row) -> Proposal:
    return Proposal(
        id=row["id"],
        version=row["version"],
        board_id=row["board_id"],
        card_id=row["card_id"],
        title=row["title"],
        body=row["body"],
        action_fingerprint=row["action_fingerprint"],
        state=ProposalState(row["state"]),
        created_at=datetime.fromisoformat(row["created_at"]),
    )


def _update(row: sqlite3.Row) -> UpdateSummary:
    return UpdateSummary(
        id=row["id"],
        board_id=row["board_id"],
        card_id=row["card_id"],
        inbox_id=row["inbox_id"],
        message_id=row["message_id"],
        summary=row["summary"],
        created_at=datetime.fromisoformat(row["created_at"]),
    )
