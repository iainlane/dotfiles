"""Drive Codex app-server's model-free effective-configuration protocol."""

from dataclasses import dataclass, field
from pathlib import Path

import msgspec

from .codex_rpc import (
    CodexRpcEmptyParameters,
    CodexRpcNotification,
    CodexRpcParameterlessRequest,
    CodexRpcRequest,
    codex_initialize_request,
    codex_rpc_line,
)
from .errors import CodexRuntimeError
from .models import ProcessExchange, ProcessOutputRecord
from .protocols.codex_app_server import (
    CodexConfigReadResponse,
    CodexConfigReadResult,
    CodexEffectiveConfiguration,
    CodexInitializeResponse,
    CodexRequirementsReadResponse,
    CodexRpcEnvelope,
)


@dataclass(eq=True)
class CodexConfigurationProbeRecordDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return (
            f"Codex returned an invalid configuration protocol record in {self.source}"
        )


@dataclass(eq=True)
class CodexConfigurationProbeResponseError(CodexRuntimeError):
    request_id: int
    code: int

    def __str__(self) -> str:
        return (
            f"Codex configuration request {self.request_id} failed with "
            f"JSON-RPC code {self.code}"
        )


@dataclass(eq=True)
class CodexConfigurationProbeResultDecodeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned an invalid effective configuration in {self.source}"


@dataclass(eq=True)
class CodexConfigurationProbeResultMissingError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex returned no effective configuration in {self.source}"


@dataclass(eq=True)
class CodexConfigurationProbeUnexpectedResponseError(CodexRuntimeError):
    expected_request_id: int
    actual_request_id: int

    def __str__(self) -> str:
        return (
            f"Codex configuration protocol expected response "
            f"{self.expected_request_id}, received {self.actual_request_id}"
        )


@dataclass(eq=True)
class CodexConfigurationProbeServerRequestError(CodexRuntimeError):
    method: str

    def __str__(self) -> str:
        return (
            "Codex app-server asked the configuration probe for "
            f"unsupported client method {self.method!r}"
        )


@dataclass(eq=True)
class CodexManagedRequirementsPresentError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return (
            f"Codex managed requirements from {self.source} may constrain the "
            "isolated judge configuration"
        )


_INITIALIZE_REQUEST_ID = 1
_CONFIGURATION_REQUEST_ID = 2
_REQUIREMENTS_REQUEST_ID = 3


class _ConfigReadParameters(msgspec.Struct, frozen=True, rename="camel"):
    include_layers: bool
    cwd: str


@dataclass
class CodexConfigurationSession:
    """Resolve effective config through the model process's app-server layers."""

    cwd: Path
    transcript: Path
    configuration: CodexEffectiveConfiguration | None = None
    _expected_request_id: int = field(default=_INITIALIZE_REQUEST_ID, init=False)
    _pending_configuration: CodexEffectiveConfiguration | None = field(
        default=None,
        init=False,
    )

    def initial_input(self) -> tuple[bytes, ...]:
        """Initialise the app-server protocol without starting a model thread."""

        return (codex_initialize_request(_INITIALIZE_REQUEST_ID),)

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        """Advance after one typed response while ignoring notifications."""

        try:
            envelope = msgspec.json.decode(record.value, type=CodexRpcEnvelope)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexConfigurationProbeRecordDecodeError(self.transcript) from error

        if envelope.id is None:
            return ProcessExchange()
        if envelope.method is not None:
            # A record carrying both an id and a method is app-server asking
            # the client something, not answering it. Reject it before the id
            # check, which reports an id collision as the wrong record.
            raise CodexConfigurationProbeServerRequestError(envelope.method)
        if envelope.id != self._expected_request_id:
            raise CodexConfigurationProbeUnexpectedResponseError(
                self._expected_request_id,
                envelope.id,
            )
        if envelope.error is not None:
            raise CodexConfigurationProbeResponseError(
                envelope.id,
                envelope.error.code,
            )
        if envelope.id == _INITIALIZE_REQUEST_ID:
            self._decode_initialize_response(record)
            self._expected_request_id = _CONFIGURATION_REQUEST_ID
            return ProcessExchange(
                writes=(
                    codex_rpc_line(
                        CodexRpcNotification(
                            method="initialized",
                            params=CodexRpcEmptyParameters(),
                        )
                    ),
                    codex_rpc_line(
                        CodexRpcRequest(
                            id=_CONFIGURATION_REQUEST_ID,
                            method="config/read",
                            params=_ConfigReadParameters(
                                include_layers=False,
                                cwd=str(self.cwd),
                            ),
                        )
                    ),
                )
            )

        if envelope.id == _CONFIGURATION_REQUEST_ID:
            self._pending_configuration = self._decode_configuration_response(
                record
            ).config
            self._expected_request_id = _REQUIREMENTS_REQUEST_ID
            return ProcessExchange(
                writes=(
                    codex_rpc_line(
                        CodexRpcParameterlessRequest(
                            id=_REQUIREMENTS_REQUEST_ID,
                            method="configRequirements/read",
                        )
                    ),
                )
            )

        requirements = self._decode_requirements_response(record)
        if requirements is not None:
            raise CodexManagedRequirementsPresentError(self.transcript)

        self.configuration = self._pending_configuration
        return ProcessExchange(close_input=True)

    def _decode_initialize_response(self, record: ProcessOutputRecord) -> None:
        try:
            response = msgspec.json.decode(record.value, type=CodexInitializeResponse)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexConfigurationProbeResultDecodeError(self.transcript) from error

        if response.result is None:
            raise CodexConfigurationProbeResultMissingError(self.transcript)

    def _decode_configuration_response(
        self,
        record: ProcessOutputRecord,
    ) -> CodexConfigReadResult:
        try:
            response = msgspec.json.decode(record.value, type=CodexConfigReadResponse)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexConfigurationProbeResultDecodeError(self.transcript) from error

        if response.result is None:
            raise CodexConfigurationProbeResultMissingError(self.transcript)

        return response.result

    def _decode_requirements_response(
        self,
        record: ProcessOutputRecord,
    ) -> dict[str, msgspec.Raw] | None:
        try:
            response = msgspec.json.decode(
                record.value,
                type=CodexRequirementsReadResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexConfigurationProbeResultDecodeError(self.transcript) from error

        if response.result is None:
            raise CodexConfigurationProbeResultMissingError(self.transcript)

        return response.result.requirements
