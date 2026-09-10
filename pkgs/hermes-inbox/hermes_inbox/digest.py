from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Protocol

from .models import UpdateSummary

NUMBER_EMOJI = (
    "1\ufe0f\u20e3",
    "2\ufe0f\u20e3",
    "3\ufe0f\u20e3",
    "4\ufe0f\u20e3",
    "5\ufe0f\u20e3",
    "6\ufe0f\u20e3",
    "7\ufe0f\u20e3",
    "8\ufe0f\u20e3",
    "9\ufe0f\u20e3",
    "\U0001f51f",
)


class DigestProposal(Protocol):
    @property
    def id(self) -> int: ...

    @property
    def version(self) -> int: ...

    @property
    def card_id(self) -> str: ...

    @property
    def title(self) -> str: ...

    @property
    def body(self) -> str: ...


@dataclass(frozen=True, slots=True)
class RenderedDigest:
    body: str
    items: tuple[tuple[int, int, str], ...]
    update_ids: tuple[int, ...]


def render_digest(
    proposals: Iterable[DigestProposal],
    updates: Iterable[UpdateSummary] = (),
    *,
    max_characters: int = 3500,
) -> RenderedDigest:
    selected: list[tuple[int, int, str]] = []
    selected_updates: list[int] = []
    lines = ["Inbox digest", "", "Proposed work"]
    for proposal, emoji in zip(proposals, NUMBER_EMOJI, strict=False):
        title = " ".join(proposal.title.split())
        if len(title) > 120:
            title = f"{title[:117]}..."
        excerpt = " ".join(proposal.body.split())
        if len(excerpt) > 180:
            excerpt = f"{excerpt[:177]}..."
        item_lines = [f"{emoji} {title} ({proposal.card_id})", excerpt]
        if len("\n".join((*lines, *item_lines))) + 160 > max_characters:
            break
        lines.extend(item_lines)
        selected.append((proposal.id, proposal.version, emoji))

    update_list = list(updates)
    if update_list:
        lines.extend(("", "Updates applied"))
    for update in update_list:
        summary = " ".join(update.summary.split())
        if len(summary) > 180:
            summary = f"{summary[:177]}..."
        item = f"• {summary} ({update.card_id})"
        if len("\n".join((*lines, item))) + 160 > max_characters:
            break
        lines.append(item)
        selected_updates.append(update.id)

    if not selected and not selected_updates:
        return RenderedDigest("No inbox proposals or updates are waiting.", (), ())

    if selected:
        lines.extend(
            (
                "",
                (
                    "React with a numbered emoji to approve that proposal. You can also "
                    "reply to this digest with /inbox approve N or /inbox dismiss N."
                ),
            )
        )
    return RenderedDigest("\n".join(lines), tuple(selected), tuple(selected_updates))
