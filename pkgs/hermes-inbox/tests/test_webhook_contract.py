from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import shutil
import sys
import time
import venv
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast
from unittest.mock import AsyncMock

import pytest

from hermes_inbox.store import InboxStore

HERMES_SOURCE = os.environ.get("HERMES_SOURCE")
if HERMES_SOURCE:
    sys.path.insert(0, HERMES_SOURCE)
pytestmark = pytest.mark.skipif(
    HERMES_SOURCE is None, reason="set HERMES_SOURCE to pinned source"
)


def _signature(body: bytes, secret: str, message_id: str, timestamp: str) -> str:
    key = base64.b64decode(secret.removeprefix("whsec_"))
    signed = b".".join((message_id.encode(), timestamp.encode(), body))
    digest = hmac.new(key, signed, hashlib.sha256).digest()
    return "v1," + base64.b64encode(digest).decode()


class Request:
    def __init__(self, body: bytes, headers: dict[str, str]) -> None:
        self._body = body
        self.headers = headers
        self.content_length = len(body)
        self.match_info = {"route_name": "agentmail"}
        self.method = "POST"

    async def read(self) -> bytes:
        return self._body


def _response(response: Any) -> tuple[int, dict[str, Any]]:
    return response.status, json.loads(response.body)


def test_native_webhook_validates_svix_and_never_dispatches_to_agent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from gateway.authz_mixin import GatewayAuthorizationMixin
    from gateway.config import PlatformConfig
    from gateway.platforms import webhook as gateway
    from gateway.platforms.base import SendResult
    from hermes_cli.plugins import PluginState

    inbox_id = "inbox-test"
    secret = "whsec_" + base64.b64encode(b"test-secret").decode()
    home = tmp_path / "home"
    scripts = home / "scripts"
    scripts.mkdir(parents=True)
    route_script = scripts / "hermes-inbox.py"
    shutil.copy2(
        Path(__file__).parents[1] / "hermes_inbox" / "route_script.py", route_script
    )
    route = {
        "events": ["message.received"],
        "secret": secret,
        "filters": [{"field": "message.inbox_id", "equals": inbox_id}],
        "script": str(route_script),
        "prompt": "AgentMail intake failed to suppress direct webhook delivery.",
        "deliver": "matrix",
        "deliver_only": True,
        "deliver_extra": {"chat_id": "!inbox:example.org"},
    }
    config = PlatformConfig(
        enabled=True,
        extra={"host": "127.0.0.1", "port": 0, "routes": {"agentmail": route}},
    )
    adapter = gateway.WebhookAdapter(config)
    adapter.handle_message = AsyncMock()
    target = SimpleNamespace(send=AsyncMock(return_value=SendResult(success=True)))

    class Runner(GatewayAuthorizationMixin):
        def __init__(self) -> None:
            self.adapters = {gateway.Platform.MATRIX: target}
            self.config = SimpleNamespace(get_home_channel=lambda _platform: None)

    adapter.gateway_runner = cast(Any, Runner())

    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("HERMES_INBOX_ID", inbox_id)
    if os.environ.get("HERMES_TEST_SOURCE_RUNTIME") == "1":
        from gateway.platforms import webhook_filters

        runtime_venv = tmp_path / "runtime"
        venv.EnvBuilder(system_site_packages=True).create(runtime_venv)
        runtime_site = (
            runtime_venv
            / "lib"
            / f"python{sys.version_info.major}.{sys.version_info.minor}"
            / "site-packages"
        )
        runtime_site.mkdir(parents=True, exist_ok=True)
        (runtime_site / "hermes-inbox-test.pth").write_text(
            "\n".join(path for path in sys.path if path) + "\n",
            encoding="utf-8",
        )
        monkeypatch.setattr(
            webhook_filters.sys, "executable", str(runtime_venv / "bin" / "python")
        )
    payload = {
        "event_type": "message.received",
        "message": {"inbox_id": inbox_id, "message_id": "message-1"},
    }
    body = json.dumps(payload, separators=(",", ":")).encode()
    timestamp = str(int(time.time()))

    invalid = Request(
        body,
        {
            "Content-Type": "application/json",
            "svix-id": "msg-invalid",
            "svix-timestamp": timestamp,
            "svix-signature": "v1,invalid",
        },
    )
    assert _response(asyncio.run(adapter._handle_webhook(invalid)))[0] == 401
    database = PluginState("hermes-inbox").data_dir / "inbox.sqlite3"
    assert not database.exists()

    valid_id = "msg-valid"
    valid = Request(
        body,
        {
            "Content-Type": "application/json",
            "svix-id": valid_id,
            "svix-timestamp": timestamp,
            "svix-signature": _signature(body, secret, valid_id, timestamp),
        },
    )
    assert _response(asyncio.run(adapter._handle_webhook(valid))) == (
        200,
        {"status": "ignored", "reason": "script", "route": "agentmail"},
    )
    queued = InboxStore(database).claim_message()
    assert queued is not None and (queued.inbox_id, queued.message_id) == (
        inbox_id,
        "message-1",
    )
    adapter.handle_message.assert_not_awaited()
    target.send.assert_not_awaited()

    malformed = scripts / "malformed.py"
    malformed.write_text(
        "#!/usr/bin/env python3\nprint('not json')\n", encoding="utf-8"
    )
    malformed.chmod(0o700)
    adapter._routes["agentmail"] = {**route, "script": str(malformed)}
    malformed_id = "msg-malformed"
    malformed_request = Request(
        body,
        {
            "Content-Type": "application/json",
            "svix-id": malformed_id,
            "svix-timestamp": timestamp,
            "svix-signature": _signature(body, secret, malformed_id, timestamp),
        },
    )
    status, response_body = _response(
        asyncio.run(adapter._handle_webhook(malformed_request))
    )
    assert status == 200
    assert response_body["status"] == "delivered"
    adapter.handle_message.assert_not_awaited()
    target.send.assert_awaited_once_with(
        "!inbox:example.org",
        "AgentMail intake failed to suppress direct webhook delivery.",
        metadata=None,
    )
