from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from hermes_inbox.agentmail import AgentMailSource
from hermes_inbox.classifier import Classifier, work_item_reference
from hermes_inbox.config import Settings, agentmail_api_key
from hermes_inbox.digest import NUMBER_EMOJI
from hermes_inbox.kanban import HermesKanban
from hermes_inbox.runtime import InboxRuntime
from hermes_inbox.store import InboxStore

_runtime: InboxRuntime | None = None


def _field(value: Any, name: str, wire_name: str | None = None) -> Any:
    if isinstance(value, Mapping):
        return value.get(wire_name or name)
    return getattr(value, name, None)


def _command_body(content: Any) -> str:
    trim_reply = getattr(content, "trim_reply_fallback", None)
    if callable(trim_reply):
        trim_reply()

    body = _field(content, "body")
    if not isinstance(body, str):
        return ""
    if not isinstance(content, Mapping) or not body.startswith("> "):
        return body

    _fallback, separator, reply = body.partition("\n\n")
    return reply if separator else body


async def _complete(
    ctx: Any, *, instructions: str, text: str, schema: dict[str, Any], schema_name: str
) -> dict[str, Any]:
    from agent.plugin_llm import PluginLlmTextInput

    result = await ctx.llm.acomplete_structured(
        instructions=instructions,
        input=[PluginLlmTextInput(text=text)],
        json_schema=schema,
        schema_name=schema_name,
        temperature=0,
        max_tokens=1000,
        timeout=60,
        purpose="Classify AgentMail intake",
        task="hermes_inbox_classification",
    )
    if not isinstance(result.parsed, dict):
        raise TypeError("inbox classifier did not return an object")
    return result.parsed


def register(ctx: Any) -> None:
    global _runtime
    settings = Settings.from_context(ctx)
    store = InboxStore(Path(ctx.state.data_dir) / "inbox.sqlite3")
    source = AgentMailSource.from_api_key(agentmail_api_key())
    adapter: Any | None = None
    matrix_native: Any | None = None
    matrix_handlers: list[tuple[Any, Any, Any]] = []
    matrix_generation = 0
    started = False
    active = True

    async def send(room_id: str, body: str) -> str:
        if adapter is None:
            raise RuntimeError("Matrix is not connected")
        result = await adapter.send(room_id, body)
        if not result.success or not result.message_id:
            raise RuntimeError(result.error or "Matrix did not return an event ID")
        return result.message_id

    async def seed_reactions(
        room_id: str, event_id: str, emojis: tuple[str, ...]
    ) -> None:
        if matrix_native is None:
            return
        from mautrix.types import EventType, RoomID

        for emoji in emojis:
            await matrix_native.send_message_event(
                RoomID(room_id),
                EventType.REACTION,
                {
                    "m.relates_to": {
                        "rel_type": "m.annotation",
                        "event_id": event_id,
                        "key": emoji,
                    }
                },
            )

    classifier = Classifier(lambda **kwargs: _complete(ctx, **kwargs))
    runtime = InboxRuntime(
        inbox_id=settings.inbox_id,
        board_id=settings.board_id,
        assignee=settings.assignee,
        room_id=settings.matrix_room_id,
        user_id=settings.matrix_user_id,
        store=store,
        source=source,
        classifier=classifier,
        kanban=HermesKanban(settings.board_id, body_limit=settings.body_limit),
        send_digest=send,
        seed_reactions=seed_reactions,
        digest_limit=settings.digest_limit,
    )
    _runtime = runtime

    ctx.register_auxiliary_task(
        "hermes_inbox_classification",
        display_name="Inbox classification",
        description="Extract references and classify AgentMail messages",
        defaults={"provider": "auto", "model": "", "timeout": 60},
    )

    def wire_webhook(_native: Any, _adapter: Any) -> None:
        nonlocal started
        if not active or started:
            return
        started = True
        ctx.spawn_task(runtime.consume(), name="hermes-inbox-consumer")
        ctx.spawn_task(runtime.schedule_digests(), name="hermes-inbox-digests")

    def wire_matrix(native: Any, matrix_adapter: Any) -> None:
        nonlocal adapter, matrix_generation, matrix_native
        if not active:
            return
        from mautrix.types import EventType

        for previous_native, event_type, handler in matrix_handlers:
            previous_native.remove_event_handler(event_type, handler)
        matrix_handlers.clear()
        matrix_generation += 1
        generation = matrix_generation
        adapter = matrix_adapter
        matrix_native = native

        async def reaction(event: Any) -> None:
            if not active or generation != matrix_generation:
                return
            content = _field(event, "content")
            relation = _field(content, "relates_to", "m.relates_to")
            event_id = _field(relation, "event_id")
            emoji = _field(relation, "key")
            if isinstance(event_id, str) and isinstance(emoji, str):
                await runtime.react(
                    room_id=str(_field(event, "room_id")),
                    user_id=str(_field(event, "sender")),
                    event_id=event_id,
                    emoji=emoji,
                )

        async def command(event: Any) -> None:
            if not active or generation != matrix_generation:
                return
            content = _field(event, "content")
            body = _command_body(content)
            if (
                str(_field(event, "room_id")) != runtime.room_id
                or str(_field(event, "sender")) != runtime.user_id
            ):
                return
            command_text = body.strip()
            if command_text == "/inbox":
                await runtime.deliver_digest(force=True)
                return
            parts = command_text.split()
            if len(parts) != 3 or parts[:2] not in (
                ["/inbox", "approve"],
                ["/inbox", "dismiss"],
            ):
                return
            try:
                number = int(parts[2])
                if not 1 <= number <= len(NUMBER_EMOJI):
                    return
                emoji = NUMBER_EMOJI[number - 1]
            except (IndexError, ValueError):
                return
            relation = _field(content, "relates_to", "m.relates_to")
            reply = _field(relation, "in_reply_to", "m.in_reply_to")
            digest_event_id = _field(reply, "event_id")
            if not isinstance(digest_event_id, str):
                return
            if parts[1] == "approve":
                await runtime.react(
                    room_id=runtime.room_id,
                    user_id=runtime.user_id,
                    event_id=digest_event_id,
                    emoji=emoji,
                )
            else:
                runtime.dismiss(
                    room_id=runtime.room_id,
                    user_id=runtime.user_id,
                    event_id=digest_event_id,
                    emoji=emoji,
                )

        native.add_event_handler(EventType.REACTION, reaction, wait_sync=True)
        native.add_event_handler(EventType.ROOM_MESSAGE, command, wait_sync=True)
        matrix_handlers.extend(
            (
                (native, EventType.REACTION, reaction),
                (native, EventType.ROOM_MESSAGE, command),
            )
        )

    def unload() -> None:
        nonlocal active, matrix_generation
        active = False
        matrix_generation += 1
        runtime.stop()
        for native, event_type, handler in matrix_handlers:
            native.remove_event_handler(event_type, handler)
        matrix_handlers.clear()

    ctx.register_platform_handler("webhook", wire_webhook)
    ctx.register_platform_handler("matrix", wire_matrix)
    ctx.register_command(
        "inbox",
        lambda _raw_args: (
            "Use /inbox in the configured Matrix room. Reply to a digest with "
            "/inbox approve N or /inbox dismiss N."
        ),
        description="Show or act on the AgentMail intake digest in Matrix.",
        args_hint="[approve|dismiss N]",
        argument_mode="mixed",
    )
    ctx.on_unload(unload)

    async def inbox_digest(_args: dict[str, Any]) -> str:
        rendered = await runtime.deliver_digest(force=True)
        return json.dumps(
            {
                "sent": bool(rendered.items or rendered.update_ids),
                "body": rendered.body,
            }
        )

    async def record_inbox_reference(args: dict[str, Any]) -> str:
        from hermes_inbox.models import CardLocation

        runtime.store.add_reference(
            CardLocation(runtime.board_id, str(args["card_id"])),
            work_item_reference(str(args["url"])),
        )
        return json.dumps({"recorded": True})

    ctx.register_tool(
        name="inbox_digest",
        toolset="kanban",
        schema={
            "name": "inbox_digest",
            "description": "Send the current inbox digest to the configured Matrix room.",
            "parameters": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        },
        handler=inbox_digest,
        is_async=True,
        description="Send the current inbox digest to the configured Matrix room.",
    )
    ctx.register_tool(
        name="record_inbox_reference",
        toolset="kanban",
        schema={
            "name": "record_inbox_reference",
            "description": "Associate an external inbox reference with an existing card.",
            "parameters": {
                "type": "object",
                "properties": {
                    "card_id": {"type": "string"},
                    "url": {
                        "type": "string",
                        "description": "Absolute work-item URL, for example https://github.com/owner/repo/issues/42.",
                    },
                },
                "required": ["card_id", "url"],
                "additionalProperties": False,
            },
        },
        handler=record_inbox_reference,
        is_async=True,
        description="Associate an external inbox reference with an existing card.",
    )
