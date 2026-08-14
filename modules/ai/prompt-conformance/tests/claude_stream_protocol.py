"""A scripted Anthropic Messages endpoint for Claude endpoint tests."""

import json
import threading
import time
from collections.abc import AsyncIterator, Sequence
from types import TracebackType
from typing import Any, Self

import msgspec
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

MESSAGES_PATH = "/v1/messages"
HELLO_PATH = "/api/hello"

type ContentBlock = dict[str, object]
type ModelReply = Sequence[ContentBlock]


class MessagesRequest(msgspec.Struct, frozen=True):
    """One decoded call to the Messages API."""

    model: str
    stream: bool = False
    messages: tuple[dict[str, Any], ...] = ()
    tools: tuple[dict[str, Any], ...] = ()

    @property
    def tool_names(self) -> tuple[str, ...]:
        return tuple(str(tool.get("name")) for tool in self.tools)

    def tool_results(self) -> tuple[dict[str, Any], ...]:
        """Return every tool_result content block the client sent back."""

        return tuple(
            block
            for message in self.messages
            for block in message.get("content", ())
            if isinstance(block, dict) and block.get("type") == "tool_result"
        )


def decode_request(body: bytes) -> MessagesRequest:
    return msgspec.json.decode(body, type=MessagesRequest)


def tool_use(identifier: str, name: str, arguments: dict[str, object]) -> ContentBlock:
    """Script one tool call the model asks the client to perform."""

    return {
        "type": "tool_use",
        "id": identifier,
        "name": name,
        "input": arguments,
    }


def text(value: str) -> ContentBlock:
    return {"type": "text", "text": value}


def sse_frame(event: str, data: dict[str, object]) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


def _stream_frames(
    identifier: str,
    model: str,
    blocks: ModelReply,
    stop_reason: str,
) -> tuple[bytes, ...]:
    """Stream one complete reply the way the Messages API chunks it."""

    frames = [
        sse_frame(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": identifier,
                    "type": "message",
                    "role": "assistant",
                    "model": model,
                    "content": [],
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                },
            },
        )
    ]
    for index, block in enumerate(blocks):
        if block["type"] == "tool_use":
            opening = dict(block, input={})
            frames.append(
                sse_frame(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": index,
                        "content_block": opening,
                    },
                )
            )
            frames.append(
                sse_frame(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": index,
                        "delta": {
                            "type": "input_json_delta",
                            "partial_json": json.dumps(block["input"]),
                        },
                    },
                )
            )
        else:
            frames.append(
                sse_frame(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": index,
                        "content_block": {"type": "text", "text": ""},
                    },
                )
            )
            frames.append(
                sse_frame(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": index,
                        "delta": {"type": "text_delta", "text": block["text"]},
                    },
                )
            )
        frames.append(
            sse_frame(
                "content_block_stop",
                {"type": "content_block_stop", "index": index},
            )
        )
    frames.append(
        sse_frame(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": 2},
            },
        )
    )
    frames.append(sse_frame("message_stop", {"type": "message_stop"}))
    return tuple(frames)


class ScriptedMessagesEndpoint:
    """Answer a fixed sequence of Messages API replies from a loopback listener."""

    def __init__(self, replies: Sequence[ModelReply]) -> None:
        self._replies = tuple(tuple(reply) for reply in replies)
        self._requests: list[MessagesRequest] = []
        self._unexpected: list[str] = []
        self._server = uvicorn.Server(
            uvicorn.Config(
                Starlette(
                    routes=[
                        Route(MESSAGES_PATH, self._respond, methods=["POST"]),
                        Route(HELLO_PATH, self._hello, methods=["GET", "POST"]),
                        Route("/{path:path}", self._unhandled, methods=["GET", "POST"]),
                    ]
                ),
                host="127.0.0.1",
                port=0,
                log_level="error",
            )
        )
        self._thread = threading.Thread(target=self._server.run, daemon=True)

    def __enter__(self) -> Self:
        self._thread.start()
        while not self._server.started:
            time.sleep(0.01)
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self._server.should_exit = True
        self._thread.join(timeout=10)

    @property
    def base_url(self) -> str:
        port = self._server.servers[0].sockets[0].getsockname()[1]
        return f"http://127.0.0.1:{port}"

    @property
    def requests(self) -> tuple[MessagesRequest, ...]:
        return tuple(self._requests)

    @property
    def unexpected_paths(self) -> tuple[str, ...]:
        return tuple(self._unexpected)

    async def _respond(self, request: Request) -> Response:
        body = await request.body()
        turn = len(self._requests)
        decoded = decode_request(body)
        self._requests.append(decoded)
        if turn >= len(self._replies):
            self._unexpected.append(f"{MESSAGES_PATH}#{turn}")
            return JSONResponse(
                {
                    "type": "error",
                    "error": {"type": "api_error", "message": "unscripted"},
                },
                status_code=500,
            )
        stop_reason = (
            "tool_use"
            if any(block["type"] == "tool_use" for block in self._replies[turn])
            else "end_turn"
        )
        frames = _stream_frames(
            f"msg-{turn}",
            decoded.model,
            self._replies[turn],
            stop_reason,
        )
        return StreamingResponse(self._stream(frames), media_type="text/event-stream")

    @staticmethod
    async def _stream(frames: tuple[bytes, ...]) -> AsyncIterator[bytes]:
        for frame in frames:
            yield frame

    async def _hello(self, request: Request) -> Response:
        return JSONResponse({"ok": True})

    async def _unhandled(self, request: Request) -> Response:
        self._unexpected.append(request.url.path)
        return JSONResponse(
            {
                "type": "error",
                "error": {"type": "not_found_error", "message": "unhandled"},
            },
            status_code=404,
        )
