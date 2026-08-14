"""A scripted model endpoint and a recording MCP transport for endpoint tests."""

import threading
import time
from collections.abc import AsyncIterator, Sequence
from pathlib import Path
from types import TracebackType
from typing import Self

import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from .codex_responses_protocol import (
    CATALOGUE_DECLINED_STATUS,
    MODELS_PATH,
    RESPONSES_PATH,
    ResponsesRequest,
    decode_request,
    output_item_done,
    response_completed,
    response_created,
    sse_frame,
)

type ModelTurn = Sequence[dict[str, object]]


class ScriptedModelEndpoint:
    """Answer a fixed sequence of model turns from a real loopback listener."""

    def __init__(self, turns: Sequence[ModelTurn]) -> None:
        self._turns = tuple(tuple(turn) for turn in turns)
        self._requests: list[ResponsesRequest] = []
        self._unexpected: list[str] = []
        self._server = uvicorn.Server(
            uvicorn.Config(
                Starlette(
                    routes=[
                        Route(RESPONSES_PATH, self._respond, methods=["POST"]),
                        Route(MODELS_PATH, self._catalogue, methods=["GET"]),
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
        return f"http://127.0.0.1:{port}/v1"

    @property
    def requests(self) -> tuple[ResponsesRequest, ...]:
        return tuple(self._requests)

    @property
    def unexpected_paths(self) -> tuple[str, ...]:
        return tuple(self._unexpected)

    async def _respond(self, request: Request) -> Response:
        body = await request.body()
        turn = len(self._requests)
        self._requests.append(decode_request(dict(request.headers), body))
        if turn >= len(self._turns):
            self._unexpected.append(f"{RESPONSES_PATH}#{turn}")
            return JSONResponse({"error": {"message": "unscripted"}}, status_code=500)
        return StreamingResponse(
            self._stream(f"resp-{turn}", self._turns[turn]),
            media_type="text/event-stream",
        )

    @staticmethod
    async def _stream(identifier: str, turn: ModelTurn) -> AsyncIterator[bytes]:
        yield sse_frame(response_created(identifier))
        for item in turn:
            yield sse_frame(output_item_done(item))
        yield sse_frame(response_completed(identifier))

    async def _catalogue(self, request: Request) -> Response:
        return Response(status_code=CATALOGUE_DECLINED_STATUS)

    async def _unhandled(self, request: Request) -> Response:
        self._unexpected.append(request.url.path)
        return JSONResponse({"error": {"message": "unhandled"}}, status_code=404)


_RECORDING_TRANSPORT = '''"""Relay one MCP stdio conversation while recording both directions."""

import subprocess
import sys
import threading
from pathlib import Path

PROGRAM = {program!r}
REQUESTS = Path({requests!r})
RESPONSES = Path({responses!r})


def relay(source, destination, transcript):
    for line in source:
        with transcript.open("ab") as log:
            log.write(line)
        destination.write(line)
        destination.flush()
    destination.close()


def main():
    child = subprocess.Popen(
        [PROGRAM, *sys.argv[1:]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    forward = threading.Thread(
        target=relay,
        args=(sys.stdin.buffer, child.stdin, REQUESTS),
        daemon=True,
    )
    forward.start()
    relay(child.stdout, sys.stdout.buffer, RESPONSES)
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
'''


def install_recording_transport(
    interpreter: str,
    program: str,
    destination: Path,
    requests: Path,
    responses: Path,
) -> str:
    """Wrap one MCP program so its stdio conversation is observable in a test."""

    destination.write_text(
        f"#!{interpreter}\n"
        + _RECORDING_TRANSPORT.format(
            program=program,
            requests=str(requests),
            responses=str(responses),
        )
    )
    destination.chmod(0o755)
    requests.touch()
    responses.touch()
    return str(destination)
