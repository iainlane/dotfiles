"""Content normalisation which does not perform network access."""

import hashlib
import json
from datetime import datetime

from bs4.element import Tag
from markdownify import MarkdownConverter

from hermes_inbox.models import EmailContent


class _SafeMarkdownConverter(MarkdownConverter):
    def convert_img(self, element: Tag, text: str, parent_tags: set[str]) -> str:
        """Render image alt text without retaining a fetchable source URL."""
        del text, parent_tags
        alt = element.get("alt", "")
        return alt if isinstance(alt, str) else ""


def normalise_email(
    *,
    message_id: str,
    thread_id: str | None,
    subject: str,
    sender: str,
    recipients: tuple[str, ...],
    received_at: datetime,
    text: str | None,
    html: str | None,
) -> EmailContent:
    """Retain the original fields and derive readable text from local content."""
    return EmailContent(
        message_id=message_id,
        thread_id=thread_id,
        subject=subject,
        sender=sender,
        recipients=recipients,
        received_at=received_at,
        text=text,
        html=html,
        readable_text=readable_body(text=text, html=html),
    )


def readable_body(
    *, text: str | None, html: str | None, extracted_text: str | None = None
) -> str:
    """Derive readable text from fields in an already-fetched email."""
    if text:
        return text
    if html:
        return (
            _SafeMarkdownConverter(
                heading_style="ATX",
                strip=["script", "style"],
            )
            .convert(html)
            .strip()
        )
    return extracted_text or ""


def action_fingerprint(title: str, body: str) -> str:
    """Return the digest used to bind approval to exact card content."""
    content = json.dumps(
        [title, body], ensure_ascii=False, separators=(",", ":")
    ).encode()
    return hashlib.sha256(content).hexdigest()
