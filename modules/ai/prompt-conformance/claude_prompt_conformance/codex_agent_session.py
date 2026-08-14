"""Drive one schema-constrained Codex role through app-server."""

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Literal

import msgspec

from .codex_rpc import (
    CodexRpcEmptyParameters,
    CodexRpcNotification,
    CodexRpcRequest,
    CodexRpcResult,
    codex_initialize_request,
    codex_rpc_line,
)
from .errors import CodexRuntimeError
from .models import ProcessExchange, ProcessOutputRecord
from .ports import CodexAuthentication
from .protocols.codex_app_server import (
    CodexAgentMessageItem,
    CodexCompletedTurn,
    CodexExternalLoginParameters,
    CodexExternalLoginResponse,
    CodexInitializeResponse,
    CodexItemCompletedNotification,
    CodexItemHeader,
    CodexRpcEnvelope,
    CodexThreadStartResponse,
    CodexTurnCompletedNotification,
    CodexTurnStartResponse,
)
from .protocols.codex_auth import (
    CodexAccessCredential,
    CodexAppServerRefreshParameters,
    CodexAppServerRefreshResult,
)


@dataclass(eq=True)
class CodexAgentProtocolRecordDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid app-server record in {self.source}"


@dataclass(eq=True)
class CodexAgentProtocolResponseError(CodexRuntimeError):
    request_id: int
    code: int

    def __str__(self) -> str:
        return (
            f"Codex app-server request {self.request_id} failed with "
            f"JSON-RPC code {self.code}"
        )


@dataclass(eq=True)
class CodexAgentProtocolUnexpectedResponseError(CodexRuntimeError):
    expected_request_id: int
    actual_request_id: int

    def __str__(self) -> str:
        return (
            f"Codex app-server expected response {self.expected_request_id}, "
            f"received {self.actual_request_id}"
        )


@dataclass(eq=True)
class CodexAgentNotificationPhaseError(CodexRuntimeError):
    method: str
    phase: str

    def __str__(self) -> str:
        return f"Codex emitted {self.method!r} while the client was {self.phase}"


@dataclass(eq=True)
class CodexAgentResponsePhaseError(CodexRuntimeError):
    response_id: int
    expected: str
    actual: str

    def __str__(self) -> str:
        return (
            f"Codex repeated response {self.response_id} while the client was "
            f"{self.actual}, not {self.expected}"
        )


@dataclass(eq=True)
class CodexAgentNotificationIdentityError(CodexRuntimeError):
    method: str
    expected_thread_id: str
    actual_thread_id: str
    expected_turn_id: str
    actual_turn_id: str

    def __str__(self) -> str:
        return (
            f"Codex {self.method!r} identified thread {self.actual_thread_id!r} "
            f"and turn {self.actual_turn_id!r}, expected "
            f"{self.expected_thread_id!r} and {self.expected_turn_id!r}"
        )


@dataclass(eq=True)
class CodexInitializeResultDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid initialize result in {self.source}"


@dataclass(eq=True)
class CodexExternalLoginResultDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid external-auth result in {self.source}"


@dataclass(eq=True)
class CodexThreadStartResultDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid thread-start result in {self.source}"


@dataclass(eq=True)
class CodexTurnStartResultDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid turn-start result in {self.source}"


@dataclass(eq=True)
class CodexExternalRefreshRequestDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid external refresh request in {self.source}"


@dataclass(eq=True)
class CodexItemCompletedDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid completed item in {self.source}"


@dataclass(eq=True)
class CodexTurnCompletedDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid completed turn in {self.source}"


@dataclass(eq=True)
class CodexUnexpectedServerRequestError(CodexRuntimeError):
    method: str

    def __str__(self) -> str:
        return f"Codex app-server requested unsupported client method {self.method!r}"


@dataclass(eq=True)
class CodexTurnTerminalStatusError(CodexRuntimeError):
    turn: CodexCompletedTurn

    def __str__(self) -> str:
        return f"Codex turn {self.turn.id} ended with status {self.turn.status}"


@dataclass(eq=True)
class CodexAgentResponseMissingError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex completed without an assistant response in {self.source}"


_INITIALIZE_REQUEST_ID = 1
_LOGIN_REQUEST_ID = 2
_THREAD_REQUEST_ID = 3
_TURN_REQUEST_ID = 4
_REFRESH_METHOD = "account/chatgptAuthTokens/refresh"


class CodexAgentPhase(StrEnum):
    """Protocol state needed to reject out-of-order model evidence."""

    INITIALIZING = "initializing"
    LOGGING_IN = "logging in"
    STARTING_THREAD = "starting a thread"
    STARTING_TURN = "starting a turn"
    RUNNING = "running a turn"
    COMPLETE = "complete"


class _ThreadStartParameters(msgspec.Struct, frozen=True, rename="camel"):
    model: str
    service_tier: str
    cwd: str
    permissions: str
    base_instructions: str
    developer_instructions: str
    personality: Literal["none"]
    ephemeral: bool


class _TextInput(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    tag="text",
    tag_field="type",
):
    text: str
    text_elements: tuple[object, ...] = ()


class _TurnStartParameters(msgspec.Struct, frozen=True, rename="camel"):
    thread_id: str
    input: tuple[_TextInput, ...]
    effort: str
    output_schema: dict[str, object]


class _ExternalRefreshRequest(
    msgspec.Struct,
    frozen=True,
    forbid_unknown_fields=True,
):
    id: int
    method: Literal["account/chatgptAuthTokens/refresh"]
    params: CodexAppServerRefreshParameters


@dataclass
class CodexAgentSession:
    """Exchange typed app-server records until one model turn completes."""

    identity: CodexAuthentication
    transcript: Path
    cwd: Path
    model: str
    effort: str
    service_tier: str
    permission_profile: str
    prompt: str
    output_schema: dict[str, object]
    response: str | None = None
    _expected_request_id: int = _INITIALIZE_REQUEST_ID
    _authentication: CodexAccessCredential | None = None
    _phase: CodexAgentPhase = CodexAgentPhase.INITIALIZING
    _thread_id: str | None = None
    _turn_id: str | None = None

    def initial_input(self) -> tuple[bytes, ...]:
        """Initialize app-server before installing external authentication."""

        return (codex_initialize_request(_INITIALIZE_REQUEST_ID),)

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        """Advance requests, refresh external auth, and retain the final response."""

        try:
            envelope = msgspec.json.decode(record.value, type=CodexRpcEnvelope)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexAgentProtocolRecordDecodeError(self.transcript) from error

        if envelope.method == _REFRESH_METHOD and envelope.id is not None:
            return self._refresh(record)
        if envelope.id is None:
            return self._receive_notification(envelope.method, record)
        if envelope.method is not None:
            raise CodexUnexpectedServerRequestError(envelope.method)
        if envelope.id != self._expected_request_id:
            raise CodexAgentProtocolUnexpectedResponseError(
                self._expected_request_id,
                envelope.id,
            )
        if envelope.error is not None:
            raise CodexAgentProtocolResponseError(envelope.id, envelope.error.code)

        self._require_response_phase(envelope.id)

        if envelope.id == _INITIALIZE_REQUEST_ID:
            return self._initialize(record)
        if envelope.id == _LOGIN_REQUEST_ID:
            return self._login(record)
        if envelope.id == _THREAD_REQUEST_ID:
            return self._start_thread(record)
        return self._start_turn(record)

    def _require_response_phase(self, response_id: int) -> None:
        expected = {
            _INITIALIZE_REQUEST_ID: CodexAgentPhase.INITIALIZING,
            _LOGIN_REQUEST_ID: CodexAgentPhase.LOGGING_IN,
            _THREAD_REQUEST_ID: CodexAgentPhase.STARTING_THREAD,
            _TURN_REQUEST_ID: CodexAgentPhase.STARTING_TURN,
        }[response_id]
        if self._phase is not expected:
            raise CodexAgentResponsePhaseError(
                response_id,
                expected.value,
                self._phase.value,
            )

    def _initialize(self, record: ProcessOutputRecord) -> ProcessExchange:
        try:
            response = msgspec.json.decode(record.value, type=CodexInitializeResponse)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexInitializeResultDecodeError(self.transcript) from error
        if response.result is None:
            raise CodexInitializeResultDecodeError(self.transcript)

        self._authentication = self.identity.authentication()
        self._expected_request_id = _LOGIN_REQUEST_ID
        self._phase = CodexAgentPhase.LOGGING_IN
        return ProcessExchange(
            writes=(
                codex_rpc_line(
                    CodexRpcNotification(
                        method="initialized",
                        params=CodexRpcEmptyParameters(),
                    )
                ),
                self._login_request(self._authentication),
            )
        )

    def _login(self, record: ProcessOutputRecord) -> ProcessExchange:
        try:
            response = msgspec.json.decode(
                record.value,
                type=CodexExternalLoginResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexExternalLoginResultDecodeError(self.transcript) from error
        if response.result is None:
            raise CodexExternalLoginResultDecodeError(self.transcript)

        self._expected_request_id = _THREAD_REQUEST_ID
        self._phase = CodexAgentPhase.STARTING_THREAD
        return ProcessExchange(
            writes=(
                codex_rpc_line(
                    CodexRpcRequest(
                        id=_THREAD_REQUEST_ID,
                        method="thread/start",
                        params=_ThreadStartParameters(
                            model=self.model,
                            service_tier=self.service_tier,
                            cwd=str(self.cwd),
                            permissions=self.permission_profile,
                            base_instructions="",
                            developer_instructions="",
                            personality="none",
                            ephemeral=True,
                        ),
                    )
                ),
            )
        )

    def _start_thread(self, record: ProcessOutputRecord) -> ProcessExchange:
        try:
            response = msgspec.json.decode(
                record.value,
                type=CodexThreadStartResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexThreadStartResultDecodeError(self.transcript) from error
        if response.result is None:
            raise CodexThreadStartResultDecodeError(self.transcript)

        self._expected_request_id = _TURN_REQUEST_ID
        self._phase = CodexAgentPhase.STARTING_TURN
        self._thread_id = response.result.thread.id
        return ProcessExchange(
            writes=(
                codex_rpc_line(
                    CodexRpcRequest(
                        id=_TURN_REQUEST_ID,
                        method="turn/start",
                        params=_TurnStartParameters(
                            thread_id=response.result.thread.id,
                            input=(_TextInput(self.prompt),),
                            effort=self.effort,
                            output_schema=self.output_schema,
                        ),
                    )
                ),
            )
        )

    def _start_turn(self, record: ProcessOutputRecord) -> ProcessExchange:
        try:
            response = msgspec.json.decode(
                record.value,
                type=CodexTurnStartResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexTurnStartResultDecodeError(self.transcript) from error
        if response.result is None:
            raise CodexTurnStartResultDecodeError(self.transcript)
        self._turn_id = response.result.turn.id
        self._phase = CodexAgentPhase.RUNNING
        return ProcessExchange()

    def _refresh(self, record: ProcessOutputRecord) -> ProcessExchange:
        try:
            request = msgspec.json.decode(
                record.value,
                type=_ExternalRefreshRequest,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexExternalRefreshRequestDecodeError(self.transcript) from error
        authentication = self._authentication
        if authentication is None:
            raise CodexExternalRefreshRequestDecodeError(self.transcript)

        authentication = self.identity.refresh(
            authentication.access_token,
            request.params.previous_account_id,
        )
        self._authentication = authentication
        return ProcessExchange(
            writes=(
                codex_rpc_line(
                    CodexRpcResult(
                        id=request.id,
                        result=CodexAppServerRefreshResult(
                            access_token=authentication.access_token,
                            chatgpt_account_id=authentication.account_id,
                            chatgpt_plan_type=authentication.plan_type,
                        ),
                    )
                ),
            )
        )

    def _receive_notification(
        self,
        method: str | None,
        record: ProcessOutputRecord,
    ) -> ProcessExchange:
        if method == "item/completed":
            self._require_running_notification(method)
            self._receive_item(record)
            return ProcessExchange()
        if method != "turn/completed":
            return ProcessExchange()

        self._require_running_notification(method)

        try:
            notification = msgspec.json.decode(
                record.value,
                type=CodexTurnCompletedNotification,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexTurnCompletedDecodeError(self.transcript) from error
        self._require_notification_identity(
            method,
            notification.params.thread_id,
            notification.params.turn.id,
        )
        if notification.params.turn.status != "completed":
            raise CodexTurnTerminalStatusError(notification.params.turn)
        if self.response is None:
            raise CodexAgentResponseMissingError(self.transcript)
        self._phase = CodexAgentPhase.COMPLETE
        return ProcessExchange(close_input=True)

    def _receive_item(self, record: ProcessOutputRecord) -> None:
        try:
            notification = msgspec.json.decode(
                record.value,
                type=CodexItemCompletedNotification,
            )
            header = msgspec.json.decode(
                notification.params.item,
                type=CodexItemHeader,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexItemCompletedDecodeError(self.transcript) from error
        self._require_notification_identity(
            "item/completed",
            notification.params.thread_id,
            notification.params.turn_id,
        )
        if header.type != "agentMessage":
            return
        try:
            item = msgspec.json.decode(
                notification.params.item,
                type=CodexAgentMessageItem,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexItemCompletedDecodeError(self.transcript) from error
        self.response = item.text

    def _require_running_notification(self, method: str) -> None:
        if self._phase is not CodexAgentPhase.RUNNING:
            raise CodexAgentNotificationPhaseError(method, self._phase.value)

    def _require_notification_identity(
        self,
        method: str,
        thread_id: str,
        turn_id: str,
    ) -> None:
        expected_thread_id = self._thread_id
        expected_turn_id = self._turn_id
        if expected_thread_id == thread_id and expected_turn_id == turn_id:
            return
        raise CodexAgentNotificationIdentityError(
            method,
            expected_thread_id or "",
            thread_id,
            expected_turn_id or "",
            turn_id,
        )

    @staticmethod
    def _login_request(authentication: CodexAccessCredential) -> bytes:
        return codex_rpc_line(
            CodexRpcRequest(
                id=_LOGIN_REQUEST_ID,
                method="account/login/start",
                params=CodexExternalLoginParameters(
                    access_token=authentication.access_token,
                    chatgpt_account_id=authentication.account_id,
                    chatgpt_plan_type=authentication.plan_type,
                ),
            )
        )
