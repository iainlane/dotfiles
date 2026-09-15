import asyncio
import hashlib
import inspect
import os
import sqlite3
import sys
from contextlib import AbstractContextManager
from datetime import UTC, datetime
from importlib import import_module
from pathlib import Path
from typing import cast

import pytest

from hermes_inbox.agentmail import AgentMailSource
from hermes_inbox.classifier import Classifier as RuntimeClassifier
from hermes_inbox.classifier import Decision, work_item_reference
from hermes_inbox.kanban import HermesKanban, email_note
from hermes_inbox.models import CardLocation, EmailContent, MessageDisposition
from hermes_inbox.runtime import InboxRuntime
from hermes_inbox.store import InboxStore

HERMES_SOURCE = os.environ.get("HERMES_SOURCE")
if HERMES_SOURCE:
    sys.path.insert(0, HERMES_SOURCE)


def _connect() -> AbstractContextManager[sqlite3.Connection]:
    connect = import_module("hermes_cli.kanban_db_connect")
    return connect.connect_closing(board="default")


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_pinned_hermes_plugin_and_kanban_contracts() -> None:
    kanban = import_module("hermes_cli.kanban_db")
    connect = import_module("hermes_cli.kanban_db_connect")
    PluginContext = import_module("hermes_cli.plugins").PluginContext
    PluginLlm = import_module("agent.plugin_llm").PluginLlm

    assert set(
        inspect.signature(PluginContext.register_platform_handler).parameters
    ) == {
        "self",
        "platform",
        "factory",
    }
    assert set(inspect.signature(PluginContext.spawn_task).parameters) == {
        "self",
        "coro",
        "name",
    }
    assert "task" in inspect.signature(PluginLlm.acomplete_structured).parameters
    assert callable(connect.connect_closing)
    assert callable(kanban.create_task)
    assert callable(kanban.get_task)
    assert callable(kanban.list_tasks)
    assert callable(kanban.add_comment)
    assert callable(kanban.specify_triage_task)


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_pinned_kanban_approval_refuses_changed_card(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = str(tmp_path)
    monkeypatch.setenv("HERMES_HOME", state)
    kanban = import_module("hermes_cli.kanban_db")
    adapter = HermesKanban("default")
    card_id, card_body = adapter.create_proposal_card(
        title="Original", body="Original body", idempotency_key="inbox:test"
    )
    with _connect() as connection:
        connection.execute(
            "UPDATE tasks SET body = ? WHERE id = ?", ("Changed body", card_id)
        )
        connection.commit()

    assert not adapter.approve_if_unchanged(
        card_id, assignee="default", title="Original", body=card_body
    )
    with _connect() as connection:
        task = kanban.get_task(connection, card_id)
    assert task is not None
    assert task.status == "triage"


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_pinned_kanban_approval_canonicalises_assignee(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    kanban = import_module("hermes_cli.kanban_db")
    adapter = HermesKanban("default")
    card_id, card_body = adapter.create_proposal_card(
        title="Original", body="Original body", idempotency_key="inbox:assignee"
    )

    assert adapter.approve_if_unchanged(
        card_id, assignee="Godfrey", title="Original", body=card_body
    )
    with _connect() as connection:
        task = kanban.get_task(connection, card_id)
    assert task is not None
    assert task.assignee == "godfrey"


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_runtime_proposal_stays_inactive_until_authorised_approval(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    store = InboxStore(tmp_path / "inbox.sqlite3")
    email = EmailContent(
        message_id="message",
        thread_id="thread",
        subject="New work",
        sender="sender@example.com",
        recipients=("work@example.com",),
        received_at=datetime(2026, 1, 1, tzinfo=UTC),
        text="Please investigate",
        html=None,
        readable_text="Please investigate",
    )

    class Classifier:
        async def extract_references(self, _email: EmailContent) -> tuple[()]:
            return ()

        async def classify_candidates(
            self, _email: EmailContent, _references: object, _candidates: object
        ) -> Decision:
            return Decision("propose", None, "Investigate failure", "new work", ())

    async def sender(room_id: str, body: str) -> str:
        assert room_id and body
        return "$digest"

    runtime = InboxRuntime(
        inbox_id="inbox",
        board_id="default",
        assignee="default",
        room_id="!room",
        user_id="@owner",
        store=store,
        source=cast(AgentMailSource, object()),
        classifier=cast(RuntimeClassifier, Classifier()),
        kanban=HermesKanban("default"),
        send_digest=sender,
    )
    assert store.enqueue_message("inbox", "message")
    assert store.claim_message() is not None
    decision, _location = asyncio.run(runtime._process(email))
    store.complete_message(
        "inbox",
        email,
        disposition=MessageDisposition.PROPOSED,
        reason=decision.reason,
        location=_location,
    )
    rendered = asyncio.run(runtime.deliver_digest())
    proposal = store.pending_for_digest()[0]
    kanban = import_module("hermes_cli.kanban_db")
    with _connect() as connection:
        before = kanban.get_task(connection, proposal.card_id)
    assert before is not None and (before.status, before.assignee) == ("triage", None)
    assert not asyncio.run(
        runtime.react(
            room_id="!wrong",
            user_id="@owner",
            event_id="$digest",
            emoji=rendered.items[0][2],
        )
    )
    assert asyncio.run(
        runtime.react(
            room_id="!room",
            user_id="@owner",
            event_id="$digest",
            emoji=rendered.items[0][2],
        )
    )
    with _connect() as connection:
        after = kanban.get_task(connection, proposal.card_id)
    assert after is not None and after.assignee == "default"


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_large_proposal_retry_keeps_one_complete_attachment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    adapter = HermesKanban("default", body_limit=80)
    body = "full source\n" * 100

    first = adapter.create_proposal_card(
        title="Large", body=body, idempotency_key="same"
    )
    second = adapter.create_proposal_card(
        title="Large", body=body, idempotency_key="same"
    )

    assert second == first
    kanban = import_module("hermes_cli.kanban_db")
    with _connect() as connection:
        attachments = kanban.list_attachments(connection, first[0])
    assert len(attachments) == 1
    assert Path(attachments[0].stored_path).read_bytes() == body.encode()


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_append_retry_uses_exact_prefix_and_preserves_full_source(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    adapter = HermesKanban("default", body_limit=100)
    kanban = import_module("hermes_cli.kanban_db")
    card_id, _body = adapter.create_proposal_card(
        title="Existing", body="card", idempotency_key="card"
    )
    message_id = "%_wildcard"
    marker = hashlib.sha256(message_id.encode()).hexdigest()
    with _connect() as connection:
        kanban.add_comment(
            connection,
            card_id,
            "hermes-inbox",
            f"Quoted [hermes-inbox-source:{marker}] later",
        )
    email = EmailContent(
        message_id=message_id,
        thread_id="thread",
        subject="Update",
        sender="sender@example.com",
        recipients=("work@example.com",),
        received_at=datetime(2026, 1, 1, tzinfo=UTC),
        text="complete\n" * 100,
        html=None,
        readable_text="complete\n" * 100,
    )

    adapter.append_email(card_id, email)
    adapter.append_email(card_id, email)

    with _connect() as connection:
        comments = kanban.list_comments(connection, card_id)
        attachments = kanban.list_attachments(connection, card_id)
    assert len(comments) == 2
    assert comments[1].body.startswith(f"[hermes-inbox-source:{marker}]")
    assert len(attachments) == 1
    assert Path(attachments[0].stored_path).read_bytes() == email_note(email).encode()


@pytest.mark.skipif(HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source")
def test_runtime_keeps_running_and_completed_cards_in_their_columns(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    kanban = import_module("hermes_cli.kanban_db")
    with _connect() as connection:
        running_id = kanban.create_task(connection, title="Running", body="body")
        completed_id = kanban.create_task(connection, title="Completed", body="body")
        connection.execute(
            "UPDATE tasks SET status = 'running' WHERE id = ?", (running_id,)
        )
        connection.execute(
            "UPDATE tasks SET status = 'done' WHERE id = ?", (completed_id,)
        )
        connection.commit()
    store = InboxStore(tmp_path / "inbox.sqlite3")
    running_ref = work_item_reference("https://github.com/owner/repo/issues/1")
    completed_ref = work_item_reference("https://github.com/owner/repo/issues/2")
    store.add_reference(CardLocation("default", running_id), running_ref)
    store.add_reference(CardLocation("default", completed_id), completed_ref)

    class FixedClassifier:
        def __init__(self, reference: object, decision: Decision) -> None:
            self.reference = reference
            self.decision = decision

        async def extract_references(self, _email: EmailContent) -> tuple[object, ...]:
            return (self.reference,)

        async def classify_candidates(
            self, _email: EmailContent, _references: object, candidates: object
        ) -> Decision:
            assert candidates
            return self.decision

    async def sender(room_id: str, body: str) -> str:
        assert room_id and body
        return "$digest"

    def runtime(classifier: FixedClassifier) -> InboxRuntime:
        return InboxRuntime(
            inbox_id="inbox",
            board_id="default",
            assignee="default",
            room_id="!room",
            user_id="@owner",
            store=store,
            source=cast(AgentMailSource, object()),
            classifier=cast(RuntimeClassifier, classifier),
            kanban=HermesKanban("default"),
            send_digest=sender,
        )

    running_email = EmailContent(
        "running-message",
        None,
        "Update",
        "sender",
        (),
        datetime.now(UTC),
        "update",
        None,
        "update",
    )
    asyncio.run(
        runtime(
            FixedClassifier(
                running_ref, Decision("append", running_id, None, "update applied", ())
            )
        )._process(running_email)
    )
    completed_email = EmailContent(
        "completed-message",
        None,
        "Follow-up",
        "sender",
        (),
        datetime.now(UTC),
        "new work",
        None,
        "new work",
    )
    _decision, new_location = asyncio.run(
        runtime(
            FixedClassifier(
                completed_ref,
                Decision("propose", completed_id, "Follow up", "new work", ()),
            )
        )._process(completed_email)
    )
    assert new_location is not None

    with _connect() as connection:
        running = kanban.get_task(connection, running_id)
        completed = kanban.get_task(connection, completed_id)
        proposed = kanban.get_task(connection, new_location.card_id)
    assert running is not None and running.status == "running"
    assert completed is not None and completed.status == "done"
    assert proposed is not None and (proposed.status, proposed.assignee) == (
        "triage",
        None,
    )
    assert f"Related card: {completed_id}" in proposed.body
