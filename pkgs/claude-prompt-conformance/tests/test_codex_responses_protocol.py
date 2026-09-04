import json
from pathlib import Path

import pytest
from compression import zstd

from .codex_responses_protocol import (
    CODE_MODE_TOOL,
    ResponsesRequest,
    assistant_message,
    code_mode_call,
    decode_request,
    mcp_tool_binding,
    mcp_tool_calls,
    mcp_tool_script,
    output_item_done,
    response_completed,
    response_created,
    sse_frame,
    tooling_warnings,
    unusable_certificate_bundle,
    warning_messages,
)

REQUEST = {
    "model": "gpt-5.6-terra",
    "input": [
        {
            "type": "additional_tools",
            "role": "developer",
            "tools": [
                {
                    "type": "namespace",
                    "name": "functions",
                    "tools": [
                        {"type": "custom", "name": "exec"},
                        {"type": "function", "name": "wait"},
                    ],
                }
            ],
        },
        {"type": "message", "role": "user", "content": [{"type": "input_text"}]},
        {
            "type": "custom_tool_call",
            "call_id": "call-1",
            "name": "exec",
            "input": "await tools.mcp__conformance__get_evaluation_brief({});",
        },
        {
            "type": "custom_tool_call_output",
            "call_id": "call-1",
            "output": [
                {"type": "input_text", "text": "Script completed\n"},
                {"type": "input_text", "text": '{"task":{}}'},
            ],
        },
    ],
}

TRANSCRIPT = b"""
{"id":1,"result":{}}
{"method":"turn/started","params":{}}
{"method":"warning","params":{"threadId":"t","message":"Code Mode is unavailable because x"}}
{"method":"warning","params":{"threadId":"t","message":"Falling back from WebSockets"}}
not json
"""

MCP_TRANSCRIPT = b"""
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_evaluation_brief"}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
"""


@pytest.mark.parametrize("compress", [False, True])
def test_the_endpoint_decodes_either_request_encoding(compress: bool) -> None:
    """Read the request whether or not the client compressed its body."""

    encoded = json.dumps(REQUEST).encode()
    headers = {"content-encoding": "zstd"} if compress else {}
    request = decode_request(headers, zstd.compress(encoded) if compress else encoded)
    assert (
        request.model,
        request.tool_names,
        request.tool_results("call-1"),
        request.tool_results("call-2"),
    ) == (
        "gpt-5.6-terra",
        ("exec", "wait"),
        ("Script completed\n", '{"task":{}}'),
        (),
    )


def test_the_endpoint_frames_one_scripted_turn() -> None:
    """Emit the created, item, and completed events one model turn needs."""

    frames = (
        sse_frame(response_created("resp-0")),
        sse_frame(output_item_done(code_mode_call("call-1", "text('hi');"))),
        sse_frame(output_item_done(assistant_message("final", "{}"))),
        sse_frame(response_completed("resp-0")),
    )
    assert tuple(
        json.loads(frame.removeprefix(b"data: ").removesuffix(b"\n\n"))
        for frame in frames
    ) == (
        {"type": "response.created", "response": {"id": "resp-0"}},
        {
            "type": "response.output_item.done",
            "item": {
                "type": "custom_tool_call",
                "call_id": "call-1",
                "name": CODE_MODE_TOOL,
                "input": "text('hi');",
            },
        },
        {
            "type": "response.output_item.done",
            "item": {
                "type": "message",
                "id": "final",
                "role": "assistant",
                "content": [{"type": "output_text", "text": "{}"}],
            },
        },
        {
            "type": "response.completed",
            "response": {
                "id": "resp-0",
                "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
            },
        },
    )


def test_the_endpoint_names_one_mcp_tool_for_the_sandbox() -> None:
    """Bind an MCP tool under the identifier the code-mode sandbox exposes."""

    assert (
        mcp_tool_binding("conformance", "get_evaluation_brief"),
        mcp_tool_script("conformance", "get_evaluation_brief"),
    ) == (
        "mcp__conformance__get_evaluation_brief",
        (
            "const result = await tools.mcp__conformance__get_evaluation_brief({});\n"
            "text(JSON.stringify(result.structuredContent ?? result));\n"
        ),
    )


def test_the_endpoint_reads_transcripts_of_a_completed_run(tmp_path: Path) -> None:
    """Recover warnings, tooling failures, and served MCP tools from transcripts."""

    bundle = unusable_certificate_bundle(tmp_path / "ca-bundle.crt")
    assert (
        warning_messages(TRANSCRIPT),
        tooling_warnings(TRANSCRIPT),
        mcp_tool_calls(MCP_TRANSCRIPT),
        bundle.read_text(),
    ) == (
        ("Code Mode is unavailable because x", "Falling back from WebSockets"),
        ("Code Mode is unavailable because x",),
        ("get_evaluation_brief",),
        "",
    )


def test_the_endpoint_ignores_a_request_without_tools_or_input() -> None:
    """Accept the minimal request shape without inventing tools or results."""

    request = decode_request({}, b'{"model":"gpt-5.6-sol"}')
    assert (request, request.tool_names) == (
        ResponsesRequest(model="gpt-5.6-sol"),
        (),
    )
