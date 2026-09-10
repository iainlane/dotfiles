from __future__ import annotations

import asyncio
import logging
from datetime import datetime, time, timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

from .agentmail import AgentMailSource
from .classifier import Candidate, Classifier, Decision
from .content import action_fingerprint
from .digest import RenderedDigest, render_digest
from .kanban import HermesKanban, email_note
from .models import (
    CardLocation,
    DigestItem,
    EmailContent,
    MessageDisposition,
    Reference,
)
from .store import InboxStore

LOGGER = logging.getLogger(__name__)
LONDON = ZoneInfo("Europe/London")


class DigestSender(Protocol):
    async def __call__(self, room_id: str, body: str) -> str: ...


class ReactionSeeder(Protocol):
    async def __call__(
        self, room_id: str, event_id: str, emojis: tuple[str, ...]
    ) -> None: ...


class InboxRuntime:
    def __init__(
        self,
        *,
        inbox_id: str,
        board_id: str,
        assignee: str,
        room_id: str,
        user_id: str,
        store: InboxStore,
        source: AgentMailSource,
        classifier: Classifier,
        kanban: HermesKanban,
        send_digest: DigestSender,
        seed_reactions: ReactionSeeder | None = None,
        digest_limit: int = 10,
    ) -> None:
        self.inbox_id = inbox_id
        self.board_id = board_id
        self.assignee = assignee
        self.room_id = room_id
        self.user_id = user_id
        self.store = store
        self.source = source
        self.classifier = classifier
        self.kanban = kanban
        self.send_digest_message = send_digest
        self.seed_reactions = seed_reactions
        self.digest_limit = digest_limit
        self._stopping = asyncio.Event()

    async def consume(self) -> None:
        while not self._stopping.is_set():
            queued = self.store.claim_message()
            if queued is None:
                try:
                    await asyncio.wait_for(self._stopping.wait(), timeout=2)
                except TimeoutError:
                    pass
                continue
            try:
                email = await asyncio.to_thread(
                    self.source.fetch, queued.inbox_id, queued.message_id
                )
                decision, location = await self._process(email)
                disposition = {
                    "ignore": MessageDisposition.IGNORED,
                    "append": MessageDisposition.ASSOCIATED,
                    "propose": MessageDisposition.PROPOSED,
                }[decision.action]
                self.store.complete_message(
                    queued.inbox_id,
                    email,
                    disposition=disposition,
                    reason=decision.reason,
                    location=location if decision.action != "ignore" else None,
                )
            except asyncio.CancelledError:
                self.store.release_message(queued.inbox_id, queued.message_id)
                raise
            except Exception as error:
                self.store.fail_message(queued.inbox_id, queued.message_id, str(error))
                LOGGER.exception(
                    "Could not process AgentMail message %s", queued.message_id
                )

    async def _process(
        self, email: EmailContent
    ) -> tuple[Decision, CardLocation | None]:
        references = await self.classifier.extract_references(email)
        trusted = (
            (Reference(self.inbox_id, "agentmail_thread", email.thread_id),)
            if email.thread_id
            else ()
        )
        all_references = (*trusted, *references)
        locations = {
            location
            for reference in all_references
            for location in self.store.find_reference(reference)
            if location.board_id == self.board_id
        }
        if locations:
            candidates = [
                candidate
                for location in locations
                if (candidate := self.kanban.get_candidate(location.card_id))
                is not None
            ]
        else:
            candidates = self.kanban.list_candidates()
        decision = await self.classifier.classify_candidates(
            email, references, candidates
        )
        location = await asyncio.to_thread(
            self._apply, email, decision, candidates, all_references
        )
        return decision, location

    def _apply(
        self,
        email: EmailContent,
        decision: Decision,
        candidates: list[Candidate],
        references: tuple[Reference, ...],
    ) -> CardLocation | None:
        if decision.action == "ignore":
            return None
        if decision.action == "append":
            assert decision.card_id is not None
            self.kanban.append_email(decision.card_id, email)
            location = CardLocation(self.board_id, decision.card_id)
            self.store.record_card_update(
                location,
                self.inbox_id,
                email.message_id,
                decision.reason,
            )
        else:
            assert decision.title is not None
            body = f"Proposed action: {decision.title}\n\n{email_note(email)}"
            if decision.card_id is not None:
                body = (
                    f"Proposed action: {decision.title}\n"
                    f"Related card: {decision.card_id}\n\n{email_note(email)}"
                )
            card_id, card_body = self.kanban.create_proposal_card(
                title=decision.title,
                body=body,
                idempotency_key=f"hermes-inbox:{self.inbox_id}:{email.message_id}",
            )
            location = CardLocation(self.board_id, card_id)
            self.store.create_proposal(
                self.board_id, card_id, decision.title, card_body
            )
        for reference in references:
            self.store.add_reference(location, reference)
        return location

    async def deliver_digest(self, *, force: bool = False) -> RenderedDigest:
        proposals = self.store.pending_for_digest(limit=self.digest_limit)
        updates = self.store.list_unreported_updates(limit=self.digest_limit)
        rendered = render_digest(proposals, updates)
        if not rendered.items and not rendered.update_ids and not force:
            return rendered
        event_id = await self.send_digest_message(self.room_id, rendered.body)
        if not rendered.items and not rendered.update_ids:
            return rendered
        items = tuple(
            DigestItem(proposal_id, version, emoji)
            for proposal_id, version, emoji in rendered.items
        )
        self.store.record_digest(self.room_id, event_id, items)
        self.store.mark_updates_reported(rendered.update_ids, self.room_id, event_id)
        if self.seed_reactions is not None and rendered.items:
            try:
                await self.seed_reactions(
                    self.room_id,
                    event_id,
                    tuple(emoji for _proposal, _version, emoji in rendered.items),
                )
            except Exception:
                LOGGER.exception("Could not add approval reactions to inbox digest")
        return rendered

    async def react(
        self, *, room_id: str, user_id: str, event_id: str, emoji: str
    ) -> bool:
        if room_id != self.room_id or user_id != self.user_id:
            return False
        proposal = self.store.resolve_digest_action(room_id, event_id, emoji)
        if proposal is None or not self._matches(
            proposal.card_id, proposal.title, proposal.body, proposal.action_fingerprint
        ):
            return False
        claimed = self.store.claim_digest_approval(room_id, event_id, emoji)
        if claimed is None:
            return False
        succeeded = False
        try:
            if not self._matches(
                claimed.card_id,
                claimed.title,
                claimed.body,
                claimed.action_fingerprint,
            ):
                return False
            succeeded = await asyncio.to_thread(
                self.kanban.approve_if_unchanged,
                claimed.card_id,
                assignee=self.assignee,
                title=claimed.title,
                body=claimed.body,
            )
            return succeeded
        finally:
            self.store.finalise_digest_approval(claimed.id, succeeded=succeeded)

    def dismiss(self, *, room_id: str, user_id: str, event_id: str, emoji: str) -> bool:
        if room_id != self.room_id or user_id != self.user_id:
            return False
        proposal = self.store.resolve_digest_action(room_id, event_id, emoji)
        return proposal is not None and self.store.dismiss_proposal(proposal.id)

    def _matches(self, card_id: str, title: str, body: str, fingerprint: str) -> bool:
        card = self.kanban.get_candidate(card_id)
        return (
            card is not None
            and card.status == "triage"
            and card.assignee is None
            and action_fingerprint(card.title, card.body) == fingerprint
            and card.title == title
            and card.body == body
        )

    async def schedule_digests(self) -> None:
        while not self._stopping.is_set():
            delay = seconds_until_next_digest(datetime.now(tz=LONDON))
            try:
                await asyncio.wait_for(self._stopping.wait(), timeout=delay)
            except TimeoutError:
                try:
                    await self.deliver_digest()
                except Exception:
                    LOGGER.exception("Could not deliver inbox digest")

    def stop(self) -> None:
        self._stopping.set()


def seconds_until_next_digest(now: datetime) -> float:
    times = (time(9), time(17))
    for target_time in times:
        target = datetime.combine(now.date(), target_time, tzinfo=LONDON)
        if target > now:
            return target.timestamp() - now.timestamp()
    tomorrow = datetime.combine(now.date() + timedelta(days=1), times[0], tzinfo=LONDON)
    return tomorrow.timestamp() - now.timestamp()
