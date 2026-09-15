from __future__ import annotations

import asyncio
import importlib.util
import re
import sys
from dataclasses import dataclass, field
from importlib import import_module
from io import StringIO
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any, cast

import pytest

PLUGIN = Path(__file__).parents[1] / "plugin" / "__init__.py"


@dataclass
class FakeRuntime:
    room_id: str = "!inbox:example.org"
    user_id: str = "@operator:example.org"
    reactions: list[dict[str, str]] = field(default_factory=list)
    dismissals: list[dict[str, str]] = field(default_factory=list)
    digests: int = 0
    stopped: bool = False

    async def consume(self) -> None:
        return

    async def schedule_digests(self) -> None:
        return

    async def react(self, **event: str) -> bool:
        self.reactions.append(event)
        return True

    def dismiss(self, **event: str) -> bool:
        self.dismissals.append(event)
        return True

    async def deliver_digest(self) -> SimpleNamespace:
        self.digests += 1
        return SimpleNamespace(items=(), update_ids=(), body="No pending inbox work.")

    def stop(self) -> None:
        self.stopped = True


class FakeContext:
    def __init__(self, data_dir: Path) -> None:
        self.state = SimpleNamespace(data_dir=data_dir)
        self.llm = SimpleNamespace()
        self.platform_handlers: dict[str, Any] = {}
        self.spawned: list[str] = []
        self.commands: dict[str, Any] = {}
        self.unload_callbacks: list[Any] = []
        self.tools: list[dict[str, Any]] = []

    def get_config(self, key: str, default: Any = None) -> Any:
        return {
            "inbox_id": "inbox-test",
            "matrix_room_id": "!inbox:example.org",
            "matrix_user_id": "@operator:example.org",
        }.get(key, default)

    def register_auxiliary_task(self, *_args: Any, **_kwargs: Any) -> None:
        return

    def register_platform_handler(self, platform: str, factory: Any) -> None:
        self.platform_handlers[platform] = factory

    def spawn_task(self, coroutine: Any, *, name: str) -> None:
        coroutine.close()
        self.spawned.append(name)

    def register_command(self, name: str, handler: Any, **_kwargs: Any) -> None:
        self.commands[name] = handler

    def on_unload(self, callback: Any) -> None:
        self.unload_callbacks.append(callback)

    def register_tool(self, **kwargs: Any) -> None:
        self.tools.append(kwargs)


class FakeNative:
    def __init__(self) -> None:
        self.handlers: dict[str, Any] = {}

    def add_event_handler(
        self, event_type: str, handler: Any, *, wait_sync: bool
    ) -> None:
        assert wait_sync is True
        self.handlers[event_type] = handler

    def remove_event_handler(self, event_type: str, handler: Any) -> None:
        if self.handlers.get(event_type) is handler:
            del self.handlers[event_type]


def load_registered_plugin(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> tuple[Any, FakeContext, FakeRuntime]:
    spec = importlib.util.spec_from_file_location("hermes_inbox_test_plugin", PLUGIN)
    assert spec is not None and spec.loader is not None
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)

    runtime = FakeRuntime()
    monkeypatch.setattr(plugin, "InboxRuntime", lambda **_kwargs: runtime)
    monkeypatch.setattr(plugin, "InboxStore", lambda _path: SimpleNamespace())
    monkeypatch.setattr(
        plugin.AgentMailSource, "from_api_key", lambda _key: SimpleNamespace()
    )
    monkeypatch.setattr(plugin, "agentmail_api_key", lambda: "test-key")
    monkeypatch.setattr(plugin, "Classifier", lambda _complete: SimpleNamespace())
    monkeypatch.setattr(
        plugin, "HermesKanban", lambda *_args, **_kwargs: SimpleNamespace()
    )

    event_types = ModuleType("mautrix.types")
    cast(Any, event_types).EventType = SimpleNamespace(
        REACTION="reaction", ROOM_MESSAGE="message"
    )
    mautrix = ModuleType("mautrix")
    cast(Any, mautrix).types = event_types
    monkeypatch.setitem(sys.modules, "mautrix", mautrix)
    monkeypatch.setitem(sys.modules, "mautrix.types", event_types)

    context = FakeContext(tmp_path)
    plugin.register(context)
    return plugin, context, runtime


def test_registers_native_hooks_and_starts_workers_once(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _plugin, context, runtime = load_registered_plugin(monkeypatch, tmp_path)

    assert set(context.platform_handlers) == {"matrix", "webhook"}
    assert set(context.commands) == {"inbox"}
    assert [tool["name"] for tool in context.tools] == [
        "inbox_digest",
        "record_inbox_reference",
    ]
    assert all(
        set(tool["schema"]) == {"name", "description", "parameters"}
        for tool in context.tools
    )
    assert context.commands["inbox"]("") == (
        "Use /inbox in the configured Matrix room. Reply to a digest with "
        "/inbox approve N or /inbox dismiss N."
    )
    first_native = FakeNative()
    context.platform_handlers["matrix"](first_native, SimpleNamespace())
    stale_reaction = first_native.handlers["reaction"]
    second_native = FakeNative()
    context.platform_handlers["matrix"](second_native, SimpleNamespace())
    assert first_native.handlers == {}
    assert set(second_native.handlers) == {"reaction", "message"}
    replaced_reaction = second_native.handlers["reaction"]
    context.platform_handlers["matrix"](second_native, SimpleNamespace())
    assert set(second_native.handlers) == {"reaction", "message"}
    stale_event = SimpleNamespace(
        room_id=runtime.room_id,
        sender=runtime.user_id,
        content=SimpleNamespace(
            relates_to=SimpleNamespace(event_id="$digest", key="1️⃣")
        ),
    )
    asyncio.run(stale_reaction(stale_event))
    asyncio.run(replaced_reaction(stale_event))
    assert runtime.reactions == []
    context.platform_handlers["webhook"](None, None)
    context.platform_handlers["webhook"](None, None)
    assert context.spawned == ["hermes-inbox-consumer", "hermes-inbox-digests"]

    assert len(context.unload_callbacks) == 1
    context.unload_callbacks[0]()
    assert first_native.handlers == {}
    assert second_native.handlers == {}
    stale_native = FakeNative()
    context.platform_handlers["matrix"](stale_native, SimpleNamespace())
    context.platform_handlers["webhook"](None, None)
    assert stale_native.handlers == {}
    assert context.spawned == ["hermes-inbox-consumer", "hermes-inbox-digests"]
    assert runtime.stopped is True


def test_native_context_registers_openai_schemas_and_unloads(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    pytest.importorskip("hermes_cli", reason="requires the pinned Hermes source")
    plugins_module = import_module("hermes_cli.plugins")
    registry = import_module("tools.registry").registry

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(
        plugins_module,
        "load_config_readonly",
        lambda: {
            "plugins": {
                "entries": {
                    "hermes-inbox": {
                        "settings": {
                            "inbox_id": "inbox-test",
                            "matrix_room_id": "!inbox:example.org",
                            "matrix_user_id": "@operator:example.org",
                        }
                    }
                }
            }
        },
    )

    spec = importlib.util.spec_from_file_location("hermes_inbox_native_plugin", PLUGIN)
    assert spec is not None and spec.loader is not None
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)

    runtime = FakeRuntime()
    runtime_arguments: dict[str, Any] = {}

    def make_runtime(**kwargs: Any) -> FakeRuntime:
        runtime_arguments.update(kwargs)
        return runtime

    monkeypatch.setattr(plugin, "InboxRuntime", make_runtime)
    monkeypatch.setattr(
        plugin.AgentMailSource, "from_api_key", lambda _key: SimpleNamespace()
    )
    monkeypatch.setattr(plugin, "agentmail_api_key", lambda: "test-key")
    monkeypatch.setattr(plugin, "Classifier", lambda _complete: SimpleNamespace())
    monkeypatch.setattr(
        plugin, "HermesKanban", lambda *_args, **_kwargs: SimpleNamespace()
    )

    manager = plugins_module.PluginManager(scope_key=str(tmp_path))
    manifest = plugins_module.PluginManifest(name="hermes-inbox", key="hermes-inbox")
    context = plugins_module.PluginContext(manifest, manager)
    plugin.register(context)

    assert cast(Any, runtime_arguments["store"])._path == (
        context.state.data_dir / "inbox.sqlite3"
    )
    # The backup service discovers this namespace without opening the live DB.
    assert re.fullmatch(
        r"agent-plugin-hermes-inbox-[0-9a-f]{8}", context.state.data_dir.name
    )
    assert manager._aux_tasks["hermes_inbox_classification"]["plugin"] == (
        "hermes-inbox"
    )
    monkeypatch.setenv("HERMES_INBOX_ID", "inbox-test")
    route_script = import_module("hermes_inbox.route_script")
    route_output = StringIO()
    assert (
        route_script.main(
            StringIO(
                '{"event_type":"message.received","message":'
                '{"inbox_id":"inbox-test","message_id":"message-test"}}'
            ),
            route_output,
        )
        == 0
    )
    store = runtime_arguments["store"]
    claimed = store.claim_message()
    assert (claimed.inbox_id, claimed.message_id) == ("inbox-test", "message-test")
    assert store.claim_message() is None

    names = {"inbox_digest", "record_inbox_reference"}
    definitions = registry.get_definitions(names)
    assert [definition["function"]["name"] for definition in definitions] == sorted(
        names
    )
    assert all(
        set(definition["function"]) == {"name", "description", "parameters"}
        for definition in definitions
    )
    assert [
        owner for _factory, owner in manager.get_platform_handler_factories("matrix")
    ] == ["hermes-inbox"]
    assert manager.unload(manifest) is True
    assert registry.get_definitions(names) == []
    stale_factory, _owner = manager.get_platform_handler_factories("matrix")[0]
    native = FakeNative()
    stale_factory(native, SimpleNamespace())
    assert native.handlers == {}
    assert runtime.stopped is True


def test_matrix_object_events_trim_replies_and_enforce_identity(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _plugin, context, runtime = load_registered_plugin(monkeypatch, tmp_path)
    native = FakeNative()
    context.platform_handlers["matrix"](native, SimpleNamespace())

    relation = SimpleNamespace(event_id="$digest", key="1️⃣")
    asyncio.run(
        native.handlers["reaction"](
            SimpleNamespace(
                room_id=runtime.room_id,
                sender=runtime.user_id,
                content=SimpleNamespace(relates_to=relation),
            )
        )
    )

    class ReplyContent:
        body = "> quoted reply\n\n/inbox approve 1"
        relates_to = SimpleNamespace(in_reply_to=SimpleNamespace(event_id="$digest"))

        def trim_reply_fallback(self) -> None:
            self.body = "/inbox approve 1"

    asyncio.run(
        native.handlers["message"](
            SimpleNamespace(
                room_id=runtime.room_id,
                sender=runtime.user_id,
                content=ReplyContent(),
            )
        )
    )
    asyncio.run(
        native.handlers["message"](
            SimpleNamespace(
                room_id=runtime.room_id,
                sender="@intruder:example.org",
                content=SimpleNamespace(body="/inbox"),
            )
        )
    )

    assert runtime.reactions == [
        {
            "room_id": runtime.room_id,
            "user_id": runtime.user_id,
            "event_id": "$digest",
            "emoji": "1️⃣",
        },
        {
            "room_id": runtime.room_id,
            "user_id": runtime.user_id,
            "event_id": "$digest",
            "emoji": "1️⃣",
        },
    ]
    assert runtime.digests == 0


def test_matrix_dict_events_support_reactions_and_reply_commands(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _plugin, context, runtime = load_registered_plugin(monkeypatch, tmp_path)
    native = FakeNative()
    context.platform_handlers["matrix"](native, SimpleNamespace())

    asyncio.run(
        native.handlers["reaction"](
            SimpleNamespace(
                room_id=runtime.room_id,
                sender=runtime.user_id,
                content={"m.relates_to": {"event_id": "$digest", "key": "2️⃣"}},
            )
        )
    )
    asyncio.run(
        native.handlers["message"](
            SimpleNamespace(
                room_id=runtime.room_id,
                sender=runtime.user_id,
                content={
                    "body": "> <@operator:example.org> quoted digest\n> second line\n\n"
                    "/inbox dismiss 2",
                    "m.relates_to": {"m.in_reply_to": {"event_id": "$digest"}},
                },
            )
        )
    )

    assert runtime.reactions == [
        {
            "room_id": runtime.room_id,
            "user_id": runtime.user_id,
            "event_id": "$digest",
            "emoji": "2️⃣",
        }
    ]
    assert runtime.dismissals == [
        {
            "room_id": runtime.room_id,
            "user_id": runtime.user_id,
            "event_id": "$digest",
            "emoji": "2️⃣",
        }
    ]
