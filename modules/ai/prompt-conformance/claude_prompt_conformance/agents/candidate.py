"""Claude candidate adapter and canonical action extraction."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import msgspec

from ..claude_session import ClaudeSdkSession
from ..errors import ConformanceError
from ..models import (
    CandidateResult,
    ClaudeBillingMode,
    Fixture,
    InstancePaths,
    NetworkAccess,
    ProcessCapabilities,
    ProcessInvocation,
    RuntimeConfiguration,
)
from ..ports import ActivityReporter, ClaudeIdentity, InteractiveProcessRunner
from ..protocols.claude import (
    CandidateAction,
    CandidateToolResult,
    CandidateToolUse,
    ClaudeContent,
    ClaudeEvent,
    ClaudeMessage,
)
from ..workspace import clean_environment


@dataclass(eq=True)
class CandidateProcessError(ConformanceError):
    return_code: int
    transcript: Path
    stderr: Path

    def __str__(self) -> str:
        return (
            f"the candidate agent failed with exit {self.return_code}; "
            f"see {self.transcript} and {self.stderr}"
        )


@dataclass(eq=True)
class CandidateSettingsFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"Claude settings {self.source} are invalid: {self.cause}"


@dataclass(eq=True)
class CandidateContextInstallError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not install candidate context from {self.source}: {self.cause}"


@dataclass(eq=True)
class CandidateInitialisationMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the candidate returned no initialisation event"


@dataclass(eq=True)
class CandidateOutputStyleError(ConformanceError):
    actual: object
    expected: str

    def __str__(self) -> str:
        return (
            f"the candidate loaded output style {self.actual!r}; "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CandidateModelError(ConformanceError):
    actual: str | None
    expected: str

    def __str__(self) -> str:
        return f"the candidate ran model {self.actual!r}; expected {self.expected!r}"


@dataclass(eq=True)
class CandidateResultError(ConformanceError):
    result: str | None
    errors: tuple[str, ...]
    terminal_reason: str | None

    def __str__(self) -> str:
        return "the candidate returned an unsuccessful terminal result"


@dataclass(eq=True)
class CandidateResponseMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the candidate returned no final response"


@dataclass(eq=True)
class CandidateEventDecodeError(ConformanceError):
    line_number: int
    cause: Exception

    def __str__(self) -> str:
        return f"candidate event {self.line_number} is invalid JSON: {self.cause}"


@dataclass(eq=True)
class CandidateEventShapeError(ConformanceError):
    line_number: int

    def __str__(self) -> str:
        return f"candidate event {self.line_number} is not an object"


class ClaudeCandidateAgent:
    """Run Claude in a fixture workspace and retain a canonical action ledger."""

    def __init__(
        self,
        configuration: RuntimeConfiguration,
        runner: InteractiveProcessRunner,
        identity: ClaudeIdentity,
    ) -> None:
        self._configuration = configuration
        self._runner = runner
        self._identity = identity

    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        transcript = artefacts / "claude-events.jsonl"
        stderr = artefacts / "claude.stderr"
        settings = instance.control / "candidate-settings.json"
        settings.write_text(
            json.dumps(
                candidate_settings(
                    self._configuration.claude.settings,
                    fixture.environment_path,
                    instance.candidate_temp,
                ),
                sort_keys=True,
            )
            + "\n"
        )
        install_candidate_context(
            self._configuration.candidate_context,
            instance.candidate_state / ".claude",
        )
        mcp_configuration = instance.control / "candidate-mcp.json"
        mcp_configuration.write_text('{"mcpServers":{}}\n')
        budget_arguments = (
            (
                "--max-budget-usd",
                self._configuration.claude.api_budget_usd,
            )
            if self._identity.billing_mode is ClaudeBillingMode.API
            else ()
        )
        session = ClaudeSdkSession(
            fixture.task.read_text(),
            self._identity,
            activity=activity,
        )
        command = (
            self._configuration.claude.program,
            "--model",
            self._configuration.claude.model,
            "--effort",
            self._configuration.claude.effort,
            "--settings",
            str(settings),
            "--setting-sources",
            "user",
            "--mcp-config",
            str(mcp_configuration),
            "--strict-mcp-config",
            "--tools",
            "default",
            "--allowedTools",
            "Agent,Bash,Edit,Glob,Grep,NotebookEdit,Read,Skill,Task,TodoWrite,WebFetch,WebSearch,Write",
            "--no-session-persistence",
            *budget_arguments,
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--print",
        )
        git_config = instance.control / "candidate-gitconfig"
        git_config.write_text("")
        environment = (
            clean_environment(fixture.environment_path)
            | self._identity.environment(instance.candidate_state)
            | {
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "CLAUDE_CODE_ENTRYPOINT": "local-agent",
                "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH": "1",
                "CLAUDE_CODE_SHELL": self._configuration.claude.shell,
                "CLAUDE_CODE_TMPDIR": str(instance.candidate_temp),
                "GIT_CONFIG_GLOBAL": str(git_config),
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_SSH_COMMAND": "false",
                "GIT_TERMINAL_PROMPT": "0",
                "TMPDIR": str(instance.candidate_temp),
                "XDG_CACHE_HOME": str(instance.candidate_cache),
                "XDG_STATE_HOME": str(instance.candidate_state),
            }
        )
        result = self._runner.run_interactive(
            ProcessInvocation(
                command=command,
                cwd=instance.workspace,
                environment=environment,
                capabilities=ProcessCapabilities(
                    writable_paths=(
                        instance.workspace,
                        instance.candidate_state,
                        instance.candidate_cache,
                        instance.candidate_temp,
                    ),
                    network=NetworkAccess.PUBLIC,
                    readable_paths=(instance.control,),
                ),
                stdout=transcript,
                stderr=stderr,
                secrets=(session.secret(),),
            ),
            session,
        )
        if not result.succeeded:
            raise CandidateProcessError(result.return_code, transcript, stderr)

        events = read_json_lines(transcript)
        response = parse_claude_response(
            events,
            self._configuration.claude.output_style,
            self._configuration.claude.model,
        )
        trace = artefacts / "candidate-actions.json"
        trace.write_bytes(msgspec.json.encode(canonical_actions(events)))
        return CandidateResult(response=response, transcript=transcript, trace=trace)


def install_candidate_context(source: Path, destination: Path) -> None:
    """Install the Nix-assembled rules and styles in the private Claude home."""

    try:
        destination.mkdir()
        for name in ("rules", "output-styles"):
            (destination / name).symlink_to(source / name, target_is_directory=True)
    except OSError as error:
        raise CandidateContextInstallError(source, destination, error) from error


def candidate_settings(
    source: Path, environment_path: str, temporary_directory: Path
) -> dict[str, Any]:
    """Add instance-specific subprocess paths to the Nix-assembled settings."""

    try:
        value = msgspec.json.decode(source.read_bytes(), type=dict[str, Any])
        environment = msgspec.convert(
            value.get("env", {}), type=dict[str, str], strict=True
        )
    except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
        raise CandidateSettingsFormatError(source, error) from error

    return value | {
        "env": environment
        | {
            "PATH": environment_path,
            "TMPDIR": str(temporary_directory),
        }
    }


def parse_claude_response(
    events: tuple[ClaudeEvent, ...], expected_style: str, expected_model: str
) -> str:
    """Extract a successful response after verifying the controlled output style."""

    initialisations = (
        event for event in events if event.type == "system" and event.subtype == "init"
    )
    try:
        initialisation = next(initialisations)
    except StopIteration as error:
        raise CandidateInitialisationMissingError from error
    actual_style = initialisation.output_style
    if actual_style != expected_style:
        raise CandidateOutputStyleError(actual_style, expected_style)
    if initialisation.model != expected_model:
        raise CandidateModelError(initialisation.model, expected_model)
    results = (event for event in reversed(events) if event.type == "result")
    try:
        terminal = next(results)
    except StopIteration as error:
        raise CandidateResultError(None, (), None) from error
    if terminal.is_error:
        raise CandidateResultError(
            terminal.result,
            terminal.errors,
            terminal.terminal_reason,
        )
    response = terminal.result
    if not response:
        raise CandidateResponseMissingError
    return response


def read_json_lines(path: Path) -> tuple[ClaudeEvent, ...]:
    """Decode Claude's stream as one typed event per line."""

    decoder = msgspec.json.Decoder(ClaudeEvent)
    events: list[ClaudeEvent] = []
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        try:
            value = decoder.decode(line)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CandidateEventDecodeError(line_number, error) from error
        events.append(value)
    return tuple(events)


def canonical_actions(events: tuple[ClaudeEvent, ...]) -> tuple[CandidateAction, ...]:
    """Extract each observable model action once from Claude's event stream."""

    actions: list[CandidateAction] = []
    for event in events:
        if event.type not in {"assistant", "user"}:
            continue
        if not isinstance(event.message, ClaudeMessage):
            continue
        actions.extend(
            canonical_action(block)
            for block in event.message.content
            if block.type in {"tool_use", "tool_result"}
        )

    return tuple(actions)


def canonical_action(block: ClaudeContent) -> CandidateAction:
    """Represent one tool action without Claude's duplicated transport fields."""

    if block.type == "tool_use":
        return CandidateToolUse(block.id, block.name, block.input)

    return CandidateToolResult(
        block.tool_use_id,
        block.content,
        block.is_error,
    )
