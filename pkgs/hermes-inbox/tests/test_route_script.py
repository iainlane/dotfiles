import json
from io import StringIO
from pathlib import Path

import pytest

from hermes_inbox.route_script import main, parse_event
from hermes_inbox.store import InboxStore


def test_route_accepts_only_received_messages_for_configured_inbox() -> None:
    payload = {
        "event_type": "message.received",
        "message": {"inbox_id": "expected", "message_id": "message"},
    }

    assert parse_event(payload, inbox_id="expected") == ("expected", "message")
    assert parse_event(payload, inbox_id="other") is None
    assert parse_event({"event_type": "message.sent"}, inbox_id="expected") is None


def test_route_enqueues_once_and_only_writes_ignore_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_INBOX_ID", "expected")
    payload = json.dumps(
        {
            "event_type": "message.received",
            "message": {"inbox_id": "expected", "message_id": "message"},
        }
    )
    first = StringIO()
    second = StringIO()

    assert main(StringIO(payload), first) == 0
    assert main(StringIO(payload), second) == 0
    assert first.getvalue() == '{"__hermes_ignore__": true}\n'
    assert second.getvalue() == first.getvalue()
    from hermes_cli.plugins import PluginState

    store = InboxStore(PluginState("hermes-inbox").data_dir / "inbox.sqlite3")
    assert store.claim_message() is not None
    assert store.claim_message() is None
