from datetime import UTC, datetime

import pytest

from hermes_inbox.content import action_fingerprint, normalise_email, readable_body


@pytest.mark.parametrize(
    ("text", "html", "expected"),
    [
        ("Plain body", "<p>ignored</p>", "Plain body"),
        (
            None,
            "<h1>Hello</h1><p>A <strong>useful</strong> body.</p>",
            "# Hello\n\nA **useful** body.",
        ),
        (None, None, ""),
    ],
)
def test_normalise_email_uses_text_then_html_fallback(
    text: str | None,
    html: str | None,
    expected: str,
) -> None:
    email = normalise_email(
        message_id="message-1",
        thread_id="thread-1",
        subject="Subject",
        sender="sender@example.com",
        recipients=("inbox@example.com",),
        received_at=datetime(2026, 9, 10, tzinfo=UTC),
        text=text,
        html=html,
    )

    assert email.readable_text == expected
    assert (email.text, email.html) == (text, html)


def test_action_fingerprint_binds_title_and_body() -> None:
    assert action_fingerprint("Title", "Body") == (
        "0ce1833b0475b60445d1024fdd9cd72d27e806eb5743973c1bea11c505353f22"
    )
    assert action_fingerprint("Title", "Body") != action_fingerprint("Title", "Changed")
    assert action_fingerprint("a\0b", "c") != action_fingerprint("a", "b\0c")


def test_readable_body_uses_extracted_text_only_when_full_content_is_absent() -> None:
    assert (
        readable_body(text=None, html=None, extracted_text="AgentMail extraction")
        == "AgentMail extraction"
    )


def test_readable_body_does_not_emit_fetchable_image_urls() -> None:
    html = '<p>Status <img alt="chart" src="https://tracker.example/pixel"></p>'

    assert readable_body(text="", html=html) == "Status chart"
