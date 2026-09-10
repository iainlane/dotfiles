from __future__ import annotations

import json
import os
import sys
from typing import Any, TextIO

IGNORE_RESPONSE = {"__hermes_ignore__": True}


def parse_event(payload: dict[str, Any], *, inbox_id: str) -> tuple[str, str] | None:
    if payload.get("event_type") != "message.received":
        return None
    event = payload.get("message")
    if not isinstance(event, dict):
        raise TypeError("message.received event has no message object")
    event_inbox = event.get("inbox_id")
    message_id = event.get("message_id")
    if event_inbox != inbox_id:
        return None
    if not isinstance(message_id, str) or not message_id.strip():
        raise ValueError("message.received event has no message_id")
    return inbox_id, message_id.strip()


def main(stdin: TextIO = sys.stdin, stdout: TextIO = sys.stdout) -> int:
    # Hermes treats stdout as the route result. Keep library diagnostics away
    # from it so they cannot accidentally dispatch the webhook to an agent.
    original_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        payload = json.load(stdin)
        if not isinstance(payload, dict):
            raise TypeError("webhook payload must be an object")
        inbox_id = os.environ["HERMES_INBOX_ID"]
        parsed = parse_event(payload, inbox_id=inbox_id)
        if parsed is not None:
            from hermes_cli.plugins import PluginState

            from hermes_inbox.store import InboxStore

            data_dir = PluginState("hermes-inbox").data_dir
            InboxStore(data_dir / "inbox.sqlite3").enqueue_message(*parsed)
    finally:
        sys.stdout = original_stdout
    json.dump(IGNORE_RESPONSE, stdout)
    stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
