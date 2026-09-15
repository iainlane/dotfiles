from __future__ import annotations

import hashlib
import sqlite3
from contextlib import AbstractContextManager
from importlib import import_module

from .classifier import Candidate
from .models import CardLocation, EmailContent


def email_note(email: EmailContent) -> str:
    recipients = ", ".join(email.recipients)
    return (
        f"Email received {email.received_at.isoformat()}\n\n"
        f"From: {email.sender}\nTo: {recipients}\n"
        f"Subject: {email.subject}\nMessage-ID: {email.message_id}\n"
        f"AgentMail thread: {email.thread_id or '(none)'}\n\n"
        f"{email.readable_text}"
    )


class HermesKanban:
    def __init__(self, board_id: str, *, body_limit: int = 60_000) -> None:
        self._board_id = board_id
        self._body_limit = body_limit

    def _connect(self) -> AbstractContextManager[sqlite3.Connection]:
        connect = import_module("hermes_cli.kanban_db_connect")
        return connect.connect_closing(board=self._board_id)

    def list_candidates(self) -> list[Candidate]:
        database = import_module("hermes_cli.kanban_db")
        with self._connect() as connection:
            tasks = database.list_tasks(
                connection, include_archived=True, order_by="created"
            )
        return [
            Candidate(
                location=CardLocation(self._board_id, task.id),
                title=task.title,
                body=task.body or "",
                status=task.status,
                assignee=task.assignee,
            )
            for task in tasks
        ]

    def get_candidate(self, card_id: str) -> Candidate | None:
        database = import_module("hermes_cli.kanban_db")
        with self._connect() as connection:
            task = database.get_task(connection, card_id)
        if task is None:
            return None
        return Candidate(
            location=CardLocation(self._board_id, task.id),
            title=task.title,
            body=task.body or "",
            status=task.status,
            assignee=task.assignee,
        )

    def create_proposal_card(
        self, *, title: str, body: str, idempotency_key: str
    ) -> tuple[str, str]:
        database = import_module("hermes_cli.kanban_db")
        card_body, attachment = self._bounded_body(body)
        source_key = hashlib.sha256(idempotency_key.encode()).hexdigest()
        attachment_name = f"agentmail-{source_key}.txt"
        with self._connect() as connection:
            card_id = database.create_task(
                connection,
                board=self._board_id,
                title=title,
                body=card_body,
                assignee=None,
                created_by="hermes-inbox",
                triage=True,
                idempotency_key=idempotency_key,
            )
            if attachment is not None:
                existing_attachment = connection.execute(
                    "SELECT 1 FROM task_attachments WHERE task_id = ? AND filename = ?",
                    (card_id, attachment_name),
                ).fetchone()
                if existing_attachment is None:
                    database.store_attachment_bytes(
                        connection,
                        card_id,
                        attachment_name,
                        attachment,
                        content_type="text/plain; charset=utf-8",
                        uploaded_by="hermes-inbox",
                        board=self._board_id,
                    )
            return card_id, card_body

    def append_email(self, card_id: str, email: EmailContent) -> None:
        database = import_module("hermes_cli.kanban_db")
        full_note = email_note(email)
        note, attachment = self._bounded_body(full_note)
        source_key = hashlib.sha256(email.message_id.encode()).hexdigest()
        marker = f"[hermes-inbox-source:{source_key}]"
        note = f"{marker}\n{note}"
        attachment_name = f"agentmail-{source_key}.txt"
        with self._connect() as connection:
            duplicate = connection.execute(
                "SELECT 1 FROM task_comments "
                "WHERE task_id = ? AND author = 'hermes-inbox' "
                "AND substr(body, 1, ?) = ? LIMIT 1",
                (card_id, len(marker), marker),
            ).fetchone()
            if duplicate is not None:
                return
            if attachment is not None:
                existing_attachment = connection.execute(
                    "SELECT 1 FROM task_attachments WHERE task_id = ? AND filename = ?",
                    (card_id, attachment_name),
                ).fetchone()
                if existing_attachment is None:
                    database.store_attachment_bytes(
                        connection,
                        card_id,
                        attachment_name,
                        attachment,
                        content_type="text/plain; charset=utf-8",
                        uploaded_by="hermes-inbox",
                        board=self._board_id,
                    )
            with database.write_txn(connection):
                duplicate = connection.execute(
                    "SELECT 1 FROM task_comments "
                    "WHERE task_id = ? AND author = 'hermes-inbox' "
                    "AND substr(body, 1, ?) = ? LIMIT 1",
                    (card_id, len(marker), marker),
                ).fetchone()
                if duplicate is not None:
                    return
                database.add_comment(connection, card_id, "hermes-inbox", note)

    def approve_if_unchanged(
        self, card_id: str, *, assignee: str, title: str, body: str
    ) -> bool:
        database = import_module("hermes_cli.kanban_db")
        profiles = import_module("hermes_cli.profiles")
        canonical_assignee = profiles.normalize_profile_name(assignee)
        with self._connect() as connection:
            with database.write_txn(connection):
                cursor = connection.execute(
                    "UPDATE tasks SET status = 'todo', assignee = ? "
                    "WHERE id = ? AND status = 'triage' AND assignee IS NULL "
                    "AND title = ? AND body = ?",
                    (canonical_assignee, card_id, title, body),
                )
                if cursor.rowcount != 1:
                    return False
                database._append_event(
                    connection, card_id, "specified", {"changed_fields": ["assignee"]}
                )
            database.recompute_ready(connection)
            return True

    def _bounded_body(self, body: str) -> tuple[str, bytes | None]:
        encoded = body.encode()
        if len(encoded) <= self._body_limit:
            return body, None
        suffix = "\n\nFull email is attached."
        excerpt_limit = self._body_limit - len(suffix.encode())
        excerpt = encoded[:excerpt_limit].decode(errors="ignore").rstrip()
        return f"{excerpt}{suffix}", encoded
