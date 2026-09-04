"""Shared typed construction for the Codex app-server JSON-RPC protocol."""

import msgspec


class CodexRpcClientInformation(msgspec.Struct, frozen=True, rename="camel"):
    """Identity reported by this app-server client."""

    name: str
    title: str
    version: str


class CodexRpcInitializeCapabilities(msgspec.Struct, frozen=True, rename="camel"):
    """Protocol extensions required by the conformance harness."""

    experimental_api: bool


class CodexRpcInitializeParameters(msgspec.Struct, frozen=True, rename="camel"):
    """Parameters sent with the shared initialize request."""

    client_info: CodexRpcClientInformation
    capabilities: CodexRpcInitializeCapabilities


class CodexRpcRequest(msgspec.Struct, frozen=True):
    """JSON-RPC request carrying typed method parameters."""

    id: int
    method: str
    params: object


class CodexRpcParameterlessRequest(msgspec.Struct, frozen=True):
    """JSON-RPC request for a method with no parameters."""

    id: int
    method: str


class CodexRpcNotification(msgspec.Struct, frozen=True):
    """JSON-RPC notification carrying typed method parameters."""

    method: str
    params: object


class CodexRpcResult(msgspec.Struct, frozen=True):
    """Response to a request initiated by Codex app-server."""

    id: int
    result: object


class CodexRpcEmptyParameters(msgspec.Struct, frozen=True):
    """Empty parameters object required by a protocol notification."""


def codex_rpc_line(value: object) -> bytes:
    """Encode one newline-delimited app-server record."""

    return msgspec.json.encode(value) + b"\n"


def codex_initialize_request(request_id: int) -> bytes:
    """Construct the common initialization request for an app-server session."""

    return codex_rpc_line(
        CodexRpcRequest(
            id=request_id,
            method="initialize",
            params=CodexRpcInitializeParameters(
                client_info=CodexRpcClientInformation(
                    name="prompt-conformance",
                    title="Prompt conformance",
                    version="1",
                ),
                capabilities=CodexRpcInitializeCapabilities(experimental_api=True),
            ),
        )
    )
