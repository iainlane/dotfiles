import asyncio
from datetime import datetime
from pathlib import Path
from typing import cast
from zoneinfo import ZoneInfo

import pytest

from hermes_inbox.agentmail import AgentMailSource
from hermes_inbox.classifier import Classifier
from hermes_inbox.kanban import HermesKanban
from hermes_inbox.models import CardLocation
from hermes_inbox.runtime import InboxRuntime, seconds_until_next_digest
from hermes_inbox.store import InboxStore


def test_digest_delay_accounts_for_spring_dst_transition() -> None:
    london = ZoneInfo("Europe/London")
    now = datetime(2026, 3, 28, 18, tzinfo=london)

    assert seconds_until_next_digest(now) == 14 * 60 * 60


def test_digest_delay_uses_later_slot_on_same_day() -> None:
    london = ZoneInfo("Europe/London")
    now = datetime(2026, 6, 1, 10, 30, tzinfo=london)

    assert seconds_until_next_digest(now) == 6.5 * 60 * 60


def test_failed_digest_send_keeps_updates_unreported(tmp_path: Path) -> None:
    store = InboxStore(tmp_path / "inbox.sqlite3")
    store.record_card_update(
        CardLocation("default", "card"),
        "inbox",
        "message",
        "Build failed",
    )

    async def fail_send(room_id: str, body: str) -> str:
        assert room_id and body
        raise RuntimeError("send failed")

    runtime = InboxRuntime(
        inbox_id="inbox",
        board_id="default",
        assignee="default",
        room_id="!room",
        user_id="@owner",
        store=store,
        source=cast(AgentMailSource, object()),
        classifier=cast(Classifier, object()),
        kanban=cast(HermesKanban, object()),
        send_digest=fail_send,
    )

    with pytest.raises(RuntimeError, match="send failed"):
        asyncio.run(runtime.deliver_digest())
    assert [update.id for update in store.list_unreported_updates()] == [1]
