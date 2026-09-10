from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from threading import Barrier

import pytest

from hermes_inbox.content import action_fingerprint, normalise_email
from hermes_inbox.models import (
    CardLocation,
    DigestItem,
    EmailContent,
    MessageDisposition,
    MessageOutcome,
    ProposalState,
    QueuedMessage,
    Reference,
)
from hermes_inbox.store import InboxStore


@pytest.fixture
def store(tmp_path: Path) -> InboxStore:
    return InboxStore(tmp_path / "state" / "inbox.sqlite3")


def email(message_id: str = "message-1") -> EmailContent:
    return normalise_email(
        message_id=message_id,
        thread_id="thread-1",
        subject="Subject",
        sender="sender@example.com",
        recipients=("inbox@example.com",),
        received_at=datetime(2026, 9, 10, 8, tzinfo=UTC),
        text="Full body",
        html="<p>Full body</p>",
    )


def test_message_queue_is_scoped_and_completes_after_fetch(store: InboxStore) -> None:
    now = datetime(2026, 9, 10, tzinfo=UTC)
    assert store.enqueue_message("first", "message-1", now=now) is True
    assert store.enqueue_message("first", "message-1") is False
    assert store.enqueue_message("second", "message-1") is True
    assert store.claim_message() == QueuedMessage(
        inbox_id="first", message_id="message-1", enqueued_at=now
    )
    store.complete_message(
        "first",
        email(),
        disposition=MessageDisposition.IGNORED,
        reason="No requested work",
    )
    assert store.enqueue_message("first", "message-1") is False
    assert store.get_message("first", "message-1") == email()
    assert store.get_message_outcome("first", "message-1") == MessageOutcome(
        disposition=MessageDisposition.IGNORED,
        reason="No requested work",
        location=None,
    )


def test_expired_message_claim_can_be_retried(store: InboxStore) -> None:
    now = datetime(2026, 9, 10, tzinfo=UTC)
    assert store.enqueue_message("inbox", "message-1", now=now)
    first_claim = store.claim_message(now=now, lease_for=timedelta(seconds=1))
    assert first_claim is not None
    assert store.claim_message(now=now + timedelta(milliseconds=500)) is None
    assert store.claim_message(now=now + timedelta(seconds=2)) == first_claim


def test_message_lease_is_compared_in_utc(store: InboxStore) -> None:
    offset = timezone(timedelta(hours=12))
    now = datetime(2026, 9, 10, 12, tzinfo=offset)
    store.enqueue_message("inbox", "message-1", now=now)
    first_claim = store.claim_message(now=now, lease_for=timedelta(minutes=1))

    assert first_claim is not None
    assert store.claim_message(now=datetime(2026, 9, 10, 0, 0, 30, tzinfo=UTC)) is None
    assert (
        store.claim_message(now=datetime(2026, 9, 10, 0, 1, 1, tzinfo=UTC))
        == first_claim
    )


def test_failed_message_does_not_starve_later_work(store: InboxStore) -> None:
    store.enqueue_message("inbox", "poison")
    store.enqueue_message("inbox", "valid")
    poison = store.claim_message()
    assert poison is not None

    store.fail_message(poison.inbox_id, poison.message_id, "invalid SDK response")

    valid = store.claim_message()
    assert valid is not None
    assert valid.message_id == "valid"
    assert store.enqueue_message("inbox", "poison") is False


def test_concurrent_webhooks_enqueue_one_job(store: InboxStore) -> None:
    with ThreadPoolExecutor(max_workers=8) as executor:
        results = tuple(
            executor.map(
                lambda _: store.enqueue_message("inbox", "message-1"),
                range(24),
            )
        )

    assert results.count(True) == 1
    assert results.count(False) == 23


def test_pending_work_survives_restart(tmp_path: Path) -> None:
    path = tmp_path / "state" / "inbox.sqlite3"
    first_store = InboxStore(path)
    first_store.enqueue_message("inbox", "message-1")

    restarted_store = InboxStore(path)

    assert restarted_store.claim_message() is not None


def test_concurrent_first_open_applies_one_complete_migration(tmp_path: Path) -> None:
    path = tmp_path / "state" / "inbox.sqlite3"
    barrier = Barrier(8)

    def open_store(_: int) -> InboxStore:
        barrier.wait()
        return InboxStore(path)

    with ThreadPoolExecutor(max_workers=8) as executor:
        stores = tuple(executor.map(open_store, range(8)))

    assert [store.enqueue_message("inbox", "message-1") for store in stores] == [
        True,
        False,
        False,
        False,
        False,
        False,
        False,
        False,
    ]


def test_references_are_scoped_and_indexed(store: InboxStore) -> None:
    reference = Reference("inbox-a", "thread", "thread-1")
    location = CardLocation("board-1", "card-1")
    store.add_reference(location, reference)
    store.add_reference(CardLocation("board-1", "card-2"), reference)

    assert store.find_reference(reference) == (
        location,
        CardLocation("board-1", "card-2"),
    )
    assert store.find_reference(Reference("inbox-b", "thread", "thread-1")) == ()


def test_digest_rejects_changed_and_old_proposals(store: InboxStore) -> None:
    proposal = store.create_proposal("board", "card", "Title", "Body")
    store.record_digest("room", "event", (DigestItem(proposal.id, 1, "1️⃣"),))

    updated = store.update_proposal(proposal.id, "Changed", "Body")

    assert updated.version == 2
    assert store.resolve_digest_action("room", "event", "1️⃣") is None
    assert store.claim_digest_approval("room", "event", "1️⃣") is None


def test_proposal_creation_is_idempotent_for_a_card(store: InboxStore) -> None:
    first = store.create_proposal("board", "card", "Title", "Body")

    assert store.create_proposal("board", "card", "Changed", "Changed") == first
    assert store.pending_for_digest() == (first,)


def test_digest_approval_can_only_be_claimed_once(store: InboxStore) -> None:
    proposal = store.create_proposal("board", "card", "Title", "Body")
    store.record_digest("room", "event", (DigestItem(proposal.id, 1, "1️⃣"),))

    claimed = store.claim_digest_approval("room", "event", "1️⃣")

    assert claimed is not None
    assert claimed.state is ProposalState.APPROVING
    assert claimed.action_fingerprint == action_fingerprint("Title", "Body")
    assert store.claim_digest_approval("room", "event", "1️⃣") is None
    assert store.finalise_digest_approval(claimed.id, succeeded=True) is True
    assert store.finalise_digest_approval(claimed.id, succeeded=True) is False


def test_digest_limits_items_and_orders_unshown_proposals_fairly(
    store: InboxStore,
) -> None:
    proposals = tuple(
        store.create_proposal("board", f"card-{index}", f"Title {index}", "Body")
        for index in range(12)
    )
    first_page = store.pending_for_digest()
    store.record_digest(
        "room",
        "event-1",
        tuple(
            DigestItem(item.id, item.version, str(index))
            for index, item in enumerate(first_page)
        ),
    )

    assert first_page == proposals[:10]
    assert store.pending_for_digest()[:2] == proposals[10:]
    with pytest.raises(ValueError, match="at most 10"):
        store.record_digest(
            "room",
            "event-2",
            tuple(
                DigestItem(item.id, item.version, str(index))
                for index, item in enumerate(proposals)
            ),
        )


def test_update_summaries_are_marked_only_after_delivery(store: InboxStore) -> None:
    update = store.record_card_update(
        CardLocation("board", "card"), "inbox", "message-1", "New reply"
    )

    assert store.list_unreported_updates() == (update,)
    store.mark_updates_reported((update.id,), "room", "event")
    assert store.list_unreported_updates() == ()


def test_update_summary_is_idempotent_for_a_message_and_card(store: InboxStore) -> None:
    location = CardLocation("board", "card")

    first = store.record_card_update(location, "inbox", "message-1", "New reply")
    duplicate = store.record_card_update(location, "inbox", "message-1", "New reply")

    assert duplicate == first
    assert store.list_unreported_updates() == (first,)
