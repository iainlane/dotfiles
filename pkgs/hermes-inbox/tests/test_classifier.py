import asyncio
from datetime import UTC, datetime

import pytest

from hermes_inbox.classifier import Candidate, Classifier, work_item_reference
from hermes_inbox.models import CardLocation, EmailContent
from hermes_inbox.store import InboxStore


def email() -> EmailContent:
    return EmailContent(
        message_id="message",
        thread_id="thread",
        subject="CI failed",
        sender="sender@example.com",
        recipients=("work@example.com",),
        received_at=datetime(2026, 1, 1, tzinfo=UTC),
        text="See owner/repo#42",
        html=None,
        readable_text="See owner/repo#42",
    )


def test_classifier_rejects_card_outside_supplied_candidates() -> None:
    responses = iter(
        [
            {
                "action": "append",
                "card_id": "other",
                "title": None,
                "reason": "same work",
            }
        ]
    )

    async def complete(**_kwargs: object) -> dict[str, object]:
        return next(responses)

    classifier = Classifier(complete)
    candidate = Candidate(CardLocation("default", "known"), "Known", "Body", "running")

    with pytest.raises(ValueError, match="outside"):
        asyncio.run(classifier.classify_candidates(email(), (), [candidate]))


def test_reference_result_is_validated_without_jsonschema() -> None:
    async def complete(**_kwargs: object) -> dict[str, object]:
        return {"urls": ["owner/repo#42"]}

    with pytest.raises(ValueError, match="absolute HTTP URL"):
        asyncio.run(Classifier(complete).extract_references(email()))


def test_work_item_url_has_one_canonical_representation() -> None:
    assert work_item_reference("HTTPS://GitHub.COM/owner/repo/issues/42/#fragment") == (
        work_item_reference("https://github.com/owner/repo/issues/42")
    )


def test_extracted_reference_matches_manually_recorded_reference(tmp_path) -> None:
    async def complete(**_kwargs: object) -> dict[str, object]:
        return {
            "urls": ["HTTPS://GitHub.COM/owner/repo/issues/42/#notification-fragment"]
        }

    location = CardLocation("default", "known")
    store = InboxStore(tmp_path / "inbox.sqlite3")
    store.add_reference(
        location,
        work_item_reference("https://github.com/owner/repo/issues/42"),
    )

    extracted = asyncio.run(Classifier(complete).extract_references(email()))

    assert extracted == (
        work_item_reference("https://github.com/owner/repo/issues/42"),
    )
    assert store.find_reference(extracted[0]) == (location,)
