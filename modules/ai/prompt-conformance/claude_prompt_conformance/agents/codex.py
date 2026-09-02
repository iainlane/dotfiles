"""Shared execution boundary for schema-constrained Codex roles."""

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

import msgspec
import tomli_w

from ..codex_agent_session import CodexAgentResponseMissingError, CodexAgentSession
from ..codex_configuration_session import (
    CodexConfigurationProbeResultDecodeError,
    CodexConfigurationProbeResultMissingError,
    CodexConfigurationSession,
)
from ..errors import CodexRuntimeError, ProcessExecutionError
from ..models import (
    CodexAgentConfiguration,
    CodexHostConfiguration,
    InstancePaths,
    NetworkAccess,
    ProcessCapabilities,
    ProcessInvocation,
    RuntimeConfiguration,
)
from ..ports import CodexIdentity, InteractiveProcessRunner
from ..protocols.codex_app_server import (
    CodexAgentsConfiguration,
    CodexBundledSkillsConfiguration,
    CodexCompactionConfiguration,
    CodexEffectiveMcpServer,
    CodexFeatureValue,
    CodexMcpEnabledState,
    CodexModelRequestConfiguration,
    CodexModelTransport,
    CodexNetworkPermissions,
    CodexPermissionProfile,
    CodexPromptIsolation,
    CodexSkillsConfiguration,
)
from ..storage import RetainedPathUnsafeError, atomic_write, reset_file
from ..workspace import clean_environment


@dataclass(eq=True)
class CodexControlDirectoryCreateError(CodexRuntimeError):
    directory: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not create isolated Codex control directory {self.directory}: {self.cause}"


@dataclass(eq=True)
class CodexControlMarkerResetError(CodexRuntimeError):
    marker: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return (
            f"could not reset isolated Codex project marker {self.marker}: {self.cause}"
        )


@dataclass(eq=True)
class CodexOutputResetError(CodexRuntimeError):
    output: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return f"could not reset isolated Codex output {self.output}: {self.cause}"


@dataclass(eq=True)
class CodexAgentPromptReadError(CodexRuntimeError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read Codex prompt {self.source}: {self.cause}"


@dataclass(eq=True)
class CodexAgentSchemaReadError(CodexRuntimeError):
    source: Path
    cause: OSError | msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"could not read Codex output schema {self.source}: {self.cause}"


@dataclass(eq=True)
class CodexInstanceConfigurationWriteError(CodexRuntimeError):
    destination: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return f"could not write isolated Codex configuration {self.destination}: {self.cause}"


@dataclass(eq=True)
class CodexAgentExecutionError(CodexRuntimeError):
    role: str
    cause: ProcessExecutionError

    def __str__(self) -> str:
        return f"Codex {self.role} process infrastructure failed: {self.cause}"


@dataclass(eq=True)
class CodexConfigurationProbeExecutionError(CodexRuntimeError):
    cause: ProcessExecutionError

    def __str__(self) -> str:
        return f"Codex configuration probe infrastructure failed: {self.cause}"


@dataclass(eq=True)
class CodexProbeArtifactResetError(CodexRuntimeError):
    destination: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return f"could not reset Codex configuration probe output {self.destination}: {self.cause}"


@dataclass(eq=True)
class CodexConfigurationProbeProcessError(CodexRuntimeError):
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return (
            f"Codex failed while resolving the isolated MCP configuration with "
            f"exit {self.return_code}; see {self.stderr}"
        )


@dataclass(eq=True)
class CodexEffectiveMcpInventoryError(CodexRuntimeError):
    actual: tuple[tuple[str, bool], ...]
    expected: tuple[tuple[str, bool], ...]

    def __str__(self) -> str:
        return (
            f"isolated Codex MCP inventory is {self.actual!r}, expected "
            f"{self.expected!r}"
        )


@dataclass(eq=True)
class CodexConformanceMcpTransportError(CodexRuntimeError):
    actual: CodexEffectiveMcpServer
    expected: CodexEffectiveMcpServer

    def __str__(self) -> str:
        return (
            f"isolated Codex conformance transport is {self.actual!r}, expected "
            f"{self.expected!r}"
        )


@dataclass(eq=True)
class CodexFeatureIsolationError(CodexRuntimeError):
    actual: dict[str, CodexFeatureValue]
    expected: dict[str, CodexFeatureValue]

    def __str__(self) -> str:
        return (
            f"isolated Codex features are {self.actual!r}, expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexAgentsIsolationError(CodexRuntimeError):
    actual: CodexAgentsConfiguration
    expected: CodexAgentsConfiguration

    def __str__(self) -> str:
        return (
            f"isolated Codex agent configuration is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexSkillsIsolationError(CodexRuntimeError):
    actual: CodexSkillsConfiguration
    expected: CodexSkillsConfiguration

    def __str__(self) -> str:
        return (
            f"isolated Codex skill configuration is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexProjectIsolationError(CodexRuntimeError):
    actual: tuple[tuple[str, ...], int]
    expected: tuple[tuple[str, ...], int]

    def __str__(self) -> str:
        return (
            f"isolated Codex project controls are {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexDefaultPermissionProfileError(CodexRuntimeError):
    actual: str
    expected: str

    def __str__(self) -> str:
        return (
            f"isolated Codex default permission profile is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexWebSearchModeError(CodexRuntimeError):
    actual: str | None

    def __str__(self) -> str:
        return f"isolated Codex web search mode is {self.actual!r}, expected 'disabled'"


@dataclass(eq=True)
class CodexPromptIsolationError(CodexRuntimeError):
    actual: CodexPromptIsolation
    expected: CodexPromptIsolation

    def __str__(self) -> str:
        return (
            f"isolated Codex prompt configuration is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexPermissionProfileError(CodexRuntimeError):
    actual: CodexPermissionProfile
    expected: CodexPermissionProfile

    def __str__(self) -> str:
        return (
            f"isolated Codex permission profile is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexModelTransportError(CodexRuntimeError):
    actual: CodexModelTransport
    expected: CodexModelTransport

    def __str__(self) -> str:
        return (
            f"isolated Codex model transport is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexCompactionIsolationError(CodexRuntimeError):
    actual: CodexCompactionConfiguration
    expected: CodexCompactionConfiguration

    def __str__(self) -> str:
        return (
            f"isolated Codex compaction configuration is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexModelRequestIsolationError(CodexRuntimeError):
    actual: CodexModelRequestConfiguration
    expected: CodexModelRequestConfiguration

    def __str__(self) -> str:
        return (
            f"isolated Codex model request configuration is {self.actual!r}, "
            f"expected {self.expected!r}"
        )


@dataclass(eq=True)
class CodexAgentOutputWriteError(CodexRuntimeError):
    destination: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return f"could not retain Codex response {self.destination}: {self.cause}"


@dataclass(eq=True)
class JudgeProcessError(CodexRuntimeError):
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return f"the judge failed with exit {self.return_code}; see {self.stderr}"


@dataclass(eq=True)
class PromptImproverProcessError(CodexRuntimeError):
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return (
            f"the prompt improver failed with exit {self.return_code}; "
            f"see {self.stderr}"
        )


class CodexRole(StrEnum):
    """The schema and permission identity of one Codex process."""

    EVALUATOR = "conformance_judge"
    IMPROVER = "prompt_improver"


@dataclass(frozen=True)
class CodexRequest:
    """All role-specific inputs to one isolated Codex invocation."""

    role: CodexRole
    prompt: Path
    schema: Path
    output: Path
    events: Path
    stderr: Path
    control: Path
    mcp_configuration: Path
    environment_path: str
    readable_paths: tuple[Path, ...]
    root: Path


class CodexStructuredAgent:
    """Run Codex with one bespoke MCP server and a strict output schema."""

    def __init__(
        self,
        configuration: RuntimeConfiguration,
        runner: InteractiveProcessRunner,
        identity: CodexIdentity,
        host_configuration: CodexHostConfiguration,
        transport: CodexModelTransport | None = None,
    ) -> None:
        self._configuration = configuration
        self._runner = runner
        self._identity = identity
        self._host_configuration = host_configuration
        self._transport = (
            transport if transport is not None else codex_model_transport()
        )

    def run(self, request: CodexRequest, instance: InstancePaths) -> None:
        try:
            request.control.mkdir(exist_ok=True)
        except OSError as error:
            raise CodexControlDirectoryCreateError(request.control, error) from error

        project_root_marker = request.control / ".claude-prompt-conformance-root"
        try:
            reset_file(instance.root, project_root_marker)
        except (OSError, RetainedPathUnsafeError) as error:
            raise CodexControlMarkerResetError(project_root_marker, error) from error
        try:
            reset_file(request.root, request.output)
        except (OSError, RetainedPathUnsafeError) as error:
            raise CodexOutputResetError(request.output, error) from error
        match request.role:
            case CodexRole.EVALUATOR:
                role_configuration = self._configuration.codex.judge
            case CodexRole.IMPROVER:
                role_configuration = self._configuration.codex.improver
        environment = (
            clean_environment(request.environment_path)
            | self._identity.environment(instance.judge_state)
            | {
                "SSL_CERT_FILE": str(self._configuration.codex.tls_certificate_bundle),
                "TMPDIR": str(instance.judge_temp),
                "XDG_CACHE_HOME": str(instance.judge_cache),
            }
        )
        instance_configuration = instance.judge_state / ".codex" / "config.toml"
        try:
            atomic_write(
                instance.root,
                instance_configuration,
                tomli_w.dumps(
                    codex_instance_configuration(
                        request,
                        role_configuration,
                        self._configuration.codex.mcp_program,
                        self._host_configuration,
                        self._transport,
                    )
                ).encode(),
            )
        except (OSError, RetainedPathUnsafeError) as error:
            raise CodexInstanceConfigurationWriteError(
                instance_configuration,
                error,
            ) from error
        capabilities = ProcessCapabilities(
            writable_paths=(
                instance.judge_state,
                instance.judge_cache,
                instance.judge_temp,
                request.control,
            ),
            readable_paths=(
                *request.readable_paths,
                request.schema,
                request.mcp_configuration,
                self._configuration.codex.tls_certificate_bundle,
            ),
            network=NetworkAccess.PUBLIC,
            writable_files=(),
        )
        self._verify_effective_configuration(
            request,
            instance,
            environment,
            capabilities,
            role_configuration,
        )
        try:
            prompt = request.prompt.read_text()
        except OSError as error:
            raise CodexAgentPromptReadError(request.prompt, error) from error
        try:
            output_schema = msgspec.json.decode(
                request.schema.read_bytes(),
                type=dict[str, object],
            )
        except OSError as error:
            raise CodexAgentSchemaReadError(request.schema, error) from error
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexAgentSchemaReadError(request.schema, error) from error
        session = CodexAgentSession(
            identity=self._identity,
            transcript=request.events,
            cwd=request.control,
            model=role_configuration.model,
            effort=role_configuration.effort,
            service_tier=role_configuration.service_tier,
            permission_profile=request.role.value,
            prompt=prompt,
            output_schema=output_schema,
        )
        try:
            result = self._runner.run_interactive(
                ProcessInvocation(
                    command=(
                        self._configuration.codex.program,
                        "app-server",
                        "--stdio",
                    ),
                    cwd=request.control,
                    environment=environment,
                    capabilities=capabilities,
                    stdout=request.events,
                    stderr=request.stderr,
                    secrets=self._identity.secrets(),
                ),
                session,
            )
        except ProcessExecutionError as error:
            raise CodexAgentExecutionError(request.role.value, error) from error
        if not result.succeeded:
            match request.role:
                case CodexRole.EVALUATOR:
                    raise JudgeProcessError(result.return_code, request.stderr)
                case CodexRole.IMPROVER:
                    raise PromptImproverProcessError(result.return_code, request.stderr)
        if session.response is None:
            raise CodexAgentResponseMissingError(request.events)
        try:
            atomic_write(request.root, request.output, session.response.encode())
        except (OSError, RetainedPathUnsafeError) as error:
            raise CodexAgentOutputWriteError(request.output, error) from error

    def _verify_effective_configuration(
        self,
        request: CodexRequest,
        instance: InstancePaths,
        environment: dict[str, str],
        capabilities: ProcessCapabilities,
        role_configuration: CodexAgentConfiguration,
    ) -> None:
        transcript = request.events.with_name(
            f"{request.events.stem}-config-read.jsonl"
        )
        stderr = request.stderr.with_name(f"{request.stderr.stem}-config-read.stderr")
        for destination in (transcript, stderr):
            try:
                reset_file(request.root, destination)
            except (OSError, RetainedPathUnsafeError) as error:
                raise CodexProbeArtifactResetError(destination, error) from error
        session = CodexConfigurationSession(request.control, transcript)
        try:
            result = self._runner.run_interactive(
                ProcessInvocation(
                    command=(
                        self._configuration.codex.program,
                        "app-server",
                        "--stdio",
                    ),
                    cwd=request.control,
                    environment=environment,
                    capabilities=capabilities,
                    stdout=transcript,
                    stderr=stderr,
                    secrets=self._identity.secrets(),
                ),
                session,
            )
        except ProcessExecutionError as error:
            raise CodexConfigurationProbeExecutionError(error) from error
        if not result.succeeded:
            raise CodexConfigurationProbeProcessError(result.return_code, stderr)
        if session.configuration is None:
            raise CodexConfigurationProbeResultMissingError(transcript)

        configuration = session.configuration
        try:
            actual_inventory = tuple(
                sorted(
                    (
                        name,
                        msgspec.json.decode(
                            server,
                            type=CodexMcpEnabledState,
                        ).enabled,
                    )
                    for name, server in configuration.mcp_servers.items()
                )
            )
            conformance = msgspec.json.decode(
                configuration.mcp_servers["conformance"],
                type=CodexEffectiveMcpServer,
            )
            permissions = msgspec.json.decode(
                configuration.permissions[request.role.value],
                type=CodexPermissionProfile,
            )
        except (KeyError, msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexConfigurationProbeResultDecodeError(transcript) from error

        expected_inventory = tuple(
            sorted(
                {
                    (name, False)
                    for name in self._host_configuration.mcp_servers
                    if name != "conformance"
                }
                | {("conformance", True)}
            )
        )
        if actual_inventory != expected_inventory:
            raise CodexEffectiveMcpInventoryError(
                actual_inventory,
                expected_inventory,
            )

        expected_conformance = CodexEffectiveMcpServer(
            command=self._configuration.codex.mcp_program,
            args=(str(request.mcp_configuration),),
            enabled=True,
            required=True,
            default_tools_approval_mode="approve",
        )
        if conformance != expected_conformance:
            raise CodexConformanceMcpTransportError(
                conformance,
                expected_conformance,
            )

        expected_features = codex_effective_isolated_features()
        if configuration.features != expected_features:
            raise CodexFeatureIsolationError(configuration.features, expected_features)

        actual_project = (
            configuration.project_root_markers,
            configuration.project_doc_max_bytes,
        )
        expected_project = (
            (".claude-prompt-conformance-root",),
            0,
        )
        if actual_project != expected_project:
            raise CodexProjectIsolationError(actual_project, expected_project)

        if configuration.default_permissions != request.role.value:
            raise CodexDefaultPermissionProfileError(
                configuration.default_permissions,
                request.role.value,
            )

        if configuration.web_search != "disabled":
            raise CodexWebSearchModeError(configuration.web_search)

        actual_prompt = CodexPromptIsolation(
            notify=configuration.notify,
            instructions=configuration.instructions,
            developer_instructions=configuration.developer_instructions,
            model_instructions_file=configuration.model_instructions_file,
            personality=configuration.personality,
        )
        expected_prompt = CodexPromptIsolation(
            notify=(),
            instructions="",
            developer_instructions="",
            model_instructions_file=None,
            personality="none",
        )
        if actual_prompt != expected_prompt:
            raise CodexPromptIsolationError(actual_prompt, expected_prompt)

        expected_agents = CodexAgentsConfiguration(enabled=False)
        if configuration.agents != expected_agents:
            raise CodexAgentsIsolationError(configuration.agents, expected_agents)

        expected_skills = CodexSkillsConfiguration(
            bundled=CodexBundledSkillsConfiguration(enabled=False),
            include_instructions=False,
        )
        if configuration.skills != expected_skills:
            raise CodexSkillsIsolationError(configuration.skills, expected_skills)

        actual_transport = CodexModelTransport(
            provider=configuration.model_provider,
            openai_base_url=configuration.openai_base_url,
            chatgpt_base_url=configuration.chatgpt_base_url,
        )
        if actual_transport != self._transport:
            raise CodexModelTransportError(actual_transport, self._transport)

        actual_compaction = CodexCompactionConfiguration(
            prompt=configuration.compact_prompt,
            token_limit=configuration.model_auto_compact_token_limit,
            token_limit_scope=configuration.model_auto_compact_token_limit_scope,
        )
        expected_compaction = CodexCompactionConfiguration(
            prompt="",
            token_limit=None,
            token_limit_scope=None,
        )
        if actual_compaction != expected_compaction:
            raise CodexCompactionIsolationError(
                actual_compaction,
                expected_compaction,
            )

        actual_request = CodexModelRequestConfiguration(
            service_tier=configuration.service_tier,
            verbosity=configuration.model_verbosity,
            context_window=configuration.model_context_window,
        )
        expected_request = CodexModelRequestConfiguration(
            service_tier=role_configuration.service_tier,
            verbosity=role_configuration.verbosity,
            context_window=role_configuration.context_window,
        )
        if actual_request != expected_request:
            raise CodexModelRequestIsolationError(actual_request, expected_request)

        expected_permissions = codex_permission_profile()
        if permissions != expected_permissions:
            raise CodexPermissionProfileError(permissions, expected_permissions)


def codex_model_transport(openai_base_url: str = "") -> CodexModelTransport:
    """Route model traffic to the subscription backend by default."""

    return CodexModelTransport(
        provider="openai",
        openai_base_url=openai_base_url,
        chatgpt_base_url="https://chatgpt.com/backend-api/",
    )


def codex_instance_configuration(
    request: CodexRequest,
    agent: CodexAgentConfiguration,
    mcp_program: str,
    host: CodexHostConfiguration,
    transport: CodexModelTransport | None = None,
) -> dict[str, object]:
    """Construct the complete instance-owned Codex configuration."""

    if transport is None:
        transport = codex_model_transport()

    mcp_servers: dict[str, object] = {
        name: {"enabled": False} for name in host.mcp_servers
    }
    mcp_servers["conformance"] = {
        "command": mcp_program,
        "args": [str(request.mcp_configuration)],
        "required": True,
        "default_tools_approval_mode": "approve",
        "enabled": True,
    }
    return {
        "model_reasoning_effort": agent.effort,
        "service_tier": agent.service_tier,
        "model_verbosity": agent.verbosity,
        "model_context_window": agent.context_window,
        "model_provider": transport.provider,
        "openai_base_url": transport.openai_base_url,
        "chatgpt_base_url": transport.chatgpt_base_url,
        "cli_auth_credentials_store": "ephemeral",
        "project_doc_max_bytes": 0,
        "project_root_markers": [".claude-prompt-conformance-root"],
        "web_search": "disabled",
        "notify": [],
        "instructions": "",
        "developer_instructions": "",
        "compact_prompt": "",
        "personality": "none",
        "features": codex_isolated_features(),
        "agents": {"enabled": False},
        "skills": {
            "bundled": {"enabled": False},
            "include_instructions": False,
        },
        "mcp_servers": mcp_servers,
        "default_permissions": request.role.value,
        "permissions": permissions_configuration(
            request.role,
        ),
    }


def permissions_configuration(
    role: CodexRole,
) -> dict[str, object]:
    """Build the filesystem and network permissions for one Codex role."""

    return {
        role.value: {
            "filesystem": {
                ":root": "deny",
            },
            "network": {"enabled": False},
        }
    }


def codex_permission_profile() -> CodexPermissionProfile:
    """Deny judge access beyond its evidence MCP and model transport."""

    return CodexPermissionProfile(
        filesystem={
            "glob_scan_max_depth": None,
            ":root": "deny",
        },
        network=CodexNetworkPermissions(enabled=False),
    )


def codex_isolated_features() -> dict[str, bool]:
    """Disable extension and model-visible tools outside the evidence MCP."""

    return {
        "apps": False,
        "auth_elicitation": False,
        "background_paginated_rollout_migration": False,
        "browser_use": False,
        "browser_use_external": False,
        "browser_use_full_cdp_access": False,
        # The GPT-5.6 models declare `tool_mode: code_mode_only`, so they can
        # reach the evidence MCP tools only through the code-mode host, which
        # runs model-written JavaScript in a V8 isolate whose tool calls are
        # delegated back through Codex. Disabling the host leaves the judge
        # with no tools at all.
        "code_mode_host": True,
        "computer_use": False,
        "goals": False,
        "hooks": False,
        "image_generation": False,
        "in_app_browser": False,
        "memories": False,
        "mcp_2026_07_28": False,
        "mentions_v2": False,
        "multi_agent": False,
        "plugins": False,
        "remote_control": False,
        "remote_plugin": False,
        "shell_snapshot": False,
        "shell_tool": False,
        "skill_mcp_dependency_install": False,
        "skill_search": False,
        "smart_approvals": False,
        "tool_suggest": False,
        "undo": False,
        "unified_exec": False,
    }


def codex_effective_isolated_features() -> dict[str, CodexFeatureValue]:
    """Represent the exact effective feature map for an isolated instance."""

    features: dict[str, CodexFeatureValue] = {"network_proxy": None}
    features.update(codex_isolated_features())
    return features
