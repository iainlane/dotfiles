from datetime import UTC, datetime

from hermes_inbox.digest import render_digest
from hermes_inbox.models import Proposal, ProposalState, UpdateSummary


def test_digest_maps_numbered_reactions_and_reports_updates() -> None:
    proposal = Proposal(
        id=7,
        version=2,
        board_id="default",
        card_id="task-1",
        title="Investigate CI",
        body="Read the complete failure report.",
        action_fingerprint="fingerprint",
        state=ProposalState.PENDING,
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    update = UpdateSummary(
        id=9,
        board_id="default",
        card_id="task-2",
        inbox_id="inbox",
        message_id="message",
        summary="Build result appended",
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )

    result = render_digest([proposal], [update])

    assert result.items == ((7, 2, "1\ufe0f\u20e3"),)
    assert result.update_ids == (9,)
    assert "task-1" in result.body
    assert "task-2" in result.body
    assert len(result.body) < 3500
