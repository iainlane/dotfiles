"""Wire shapes the pinned Codex client expects from an OpenAI Responses endpoint.

EVERY value in this module is coupled to the pinned Codex version. A Codex
upgrade which changes the Responses protocol, the code-mode tool contract, or
the model-catalogue fallback must break this file rather than silently degrade
the judge. The shapes were read from the Codex source tree, in `codex-rs`:

- `codex-api/src/sse/responses.rs` frames every model event as one `data:` line
  and stops the turn at `response.completed`.
- `protocol/src/models.rs` tags each `ResponseItem` with `type` in snake case,
  so the model speaks `custom_tool_call` and `message`.
- `code-mode-protocol/src/lib.rs` names the code-mode tool `exec`, and
  `code-mode-protocol/src/description.rs` exposes MCP tools to the sandbox as
  `tools.mcp__<server>__<tool>` JavaScript identifiers.
- `core/src/tools/code_mode/mod.rs` prefixes each `exec` result with a status
  line, so a completed script reports `Script completed`.
- `core/src/client.rs` sends the judged models their tool catalogue in an
  `additional_tools` conversation item holding one `functions` namespace,
  rather than in the request's own `tools` array.
- `core/src/client.rs` compresses request bodies with zstd whenever the
  provider is `openai` and the account uses the subscription backend.
- `core/src/client.rs` prefers a WebSocket transport, which this endpoint does
  not speak, and reaches the plain HTTP transport only once the WebSocket
  client fails to build.
- `models-manager/models.json` is compiled into the client and already declares
  `tool_mode = "code_mode_only"` for the judged models, so the endpoint must
  refuse `/models` and let the client keep its own catalogue.
- `core/src/tools/code_mode/mod.rs` reports a judge which cannot reach its MCP
  tools as a warning beginning `Code Mode is unavailable`, which
  `app-server/src/bespoke_event_handling.rs` forwards as a `warning`
  notification.
"""

import json
from pathlib import Path
from typing import Literal

import msgspec
from compression import zstd

RESPONSES_PATH = "/v1/responses"
MODELS_PATH = "/v1/models"
CATALOGUE_DECLINED_STATUS = 404
CODE_MODE_TOOL = "exec"
CODE_MODE_TOOLS = ("exec", "wait", "request_user_input")
CODE_MODE_COMPLETED_STATUS = "Script completed"
CODE_MODE_UNAVAILABLE_WARNING = "Code Mode is unavailable"


def unusable_certificate_bundle(destination: Path) -> Path:
    """Write the certificate bundle which keeps the client on plain HTTP.

    The pinned client prefers a WebSocket transport for `/responses`, which the
    scripted endpoint cannot speak. A bundle it refuses to load fails WebSocket
    client construction and leaves only the HTTP transport the endpoint serves.
    """

    destination.write_text("")
    return destination


class ResponsesToolSpec(msgspec.Struct, frozen=True):
    """One entry of the tool catalogue, which may group nested tools."""

    type: str
    name: str | None = None
    tools: tuple["ResponsesToolSpec", ...] = ()

    @property
    def names(self) -> tuple[str, ...]:
        if self.tools:
            return tuple(name for tool in self.tools for name in tool.names)
        return (self.name,) if self.name is not None else ()


class ResponsesToolOutput(msgspec.Struct, frozen=True):
    """One content block of a tool result returned to the model."""

    type: str
    text: str


class ResponsesInputItem(msgspec.Struct, frozen=True):
    """One conversation item replayed to the model on a follow-up request."""

    type: str
    call_id: str | None = None
    name: str | None = None
    input: str | None = None
    output: tuple[ResponsesToolOutput, ...] | str | None = None
    tools: tuple[ResponsesToolSpec, ...] = ()


class ResponsesRequest(msgspec.Struct, frozen=True):
    """The parts of a Responses request an endpoint test asserts on."""

    model: str
    tools: tuple[ResponsesToolSpec, ...] = ()
    input: tuple[ResponsesInputItem, ...] = ()

    @property
    def tool_names(self) -> tuple[str, ...]:
        """List every offered tool, flattening the responses-lite namespace."""

        offered = (*self.tools, *(tool for item in self.input for tool in item.tools))
        return tuple(name for tool in offered for name in tool.names)

    def tool_results(self, call_id: str) -> tuple[str, ...]:
        """Return the text blocks Codex sent back for one tool call."""

        return tuple(
            block.text
            for item in self.input
            if item.call_id == call_id and isinstance(item.output, tuple)
            for block in item.output
        )


def decode_request(headers: dict[str, str], body: bytes) -> ResponsesRequest:
    """Decode one Responses request, undoing the client's zstd compression."""

    if headers.get("content-encoding") == "zstd":
        body = zstd.decompress(body)
    return msgspec.json.decode(body, type=ResponsesRequest)


def sse_frame(event: dict[str, object]) -> bytes:
    """Frame one model event the way the client's event-source reader expects."""

    return f"data: {json.dumps(event)}\n\n".encode()


def response_created(identifier: str) -> dict[str, object]:
    """Announce the response the client is about to receive."""

    return {"type": "response.created", "response": {"id": identifier}}


def output_item_done(item: dict[str, object]) -> dict[str, object]:
    """Deliver one completed output item."""

    return {"type": "response.output_item.done", "item": item}


def response_completed(identifier: str) -> dict[str, object]:
    """End the turn, which is the only event that stops the client reading."""

    return {
        "type": "response.completed",
        "response": {
            "id": identifier,
            "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
        },
    }


def mcp_tool_binding(server: str, tool: str) -> str:
    """Name one MCP tool as the code-mode sandbox exposes it to the model."""

    return f"mcp__{server}__{tool}"


def mcp_tool_script(server: str, tool: str) -> str:
    """Write the sandbox program which calls one MCP tool and reports it."""

    binding = mcp_tool_binding(server, tool)
    return (
        f"const result = await tools.{binding}({{}});\n"
        "text(JSON.stringify(result.structuredContent ?? result));\n"
    )


def code_mode_call(call_id: str, script: str) -> dict[str, object]:
    """Ask the client to run one sandbox program through the code-mode host."""

    return {
        "type": "custom_tool_call",
        "call_id": call_id,
        "name": CODE_MODE_TOOL,
        "input": script,
    }


def assistant_message(identifier: str, text: str) -> dict[str, object]:
    """Return the final assistant message the agent session reads its answer from."""

    return {
        "type": "message",
        "id": identifier,
        "role": "assistant",
        "content": [{"type": "output_text", "text": text}],
    }


class WarningParameters(msgspec.Struct, frozen=True):
    """The text of one app-server warning."""

    message: str


class WarningNotification(msgspec.Struct, frozen=True):
    """One warning the app-server raised during a run."""

    method: Literal["warning"]
    params: WarningParameters


def warning_messages(transcript: bytes) -> tuple[str, ...]:
    """List every warning the app-server emitted during a run."""

    messages = []
    for line in transcript.splitlines():
        if not line.strip():
            continue
        try:
            record = msgspec.json.decode(line, type=WarningNotification)
        except (msgspec.DecodeError, msgspec.ValidationError):
            continue
        messages.append(record.params.message)
    return tuple(messages)


def tooling_warnings(transcript: bytes) -> tuple[str, ...]:
    """List the warnings which report a judge cut off from its MCP tools."""

    return tuple(
        message
        for message in warning_messages(transcript)
        if CODE_MODE_UNAVAILABLE_WARNING in message
    )


class McpToolCallParameters(msgspec.Struct, frozen=True):
    """The tool selected by one MCP `tools/call` request."""

    name: str


class McpToolCall(msgspec.Struct, frozen=True):
    """One MCP request which invokes a tool."""

    method: Literal["tools/call"]
    params: McpToolCallParameters


def mcp_tool_calls(transcript: bytes) -> tuple[str, ...]:
    """List every tool the evaluator MCP server was actually asked to run."""

    calls = []
    for line in transcript.splitlines():
        if not line.strip():
            continue
        try:
            record = msgspec.json.decode(line, type=McpToolCall)
        except (msgspec.DecodeError, msgspec.ValidationError):
            continue
        calls.append(record.params.name)
    return tuple(calls)
