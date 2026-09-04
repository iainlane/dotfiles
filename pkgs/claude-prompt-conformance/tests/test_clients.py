import json
import tomllib
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import cast

import msgspec
import pytest

from claude_prompt_conformance.agents.candidate import (
    CandidateModelError,
    CandidateOutputStyleError,
    read_json_lines,
)
from claude_prompt_conformance.agents.codex import (
    CodexAgentExecutionError,
    CodexAgentsIsolationError,
    CodexCompactionIsolationError,
    CodexConfigurationProbeExecutionError,
    CodexConfigurationProbeProcessError,
    CodexConformanceMcpTransportError,
    CodexDefaultPermissionProfileError,
    CodexEffectiveMcpInventoryError,
    CodexFeatureIsolationError,
    CodexInstanceConfigurationWriteError,
    CodexModelRequestIsolationError,
    CodexModelTransportError,
    CodexPermissionProfileError,
    CodexProjectIsolationError,
    CodexPromptIsolationError,
    CodexRequest,
    CodexRole,
    CodexSkillsIsolationError,
    CodexStructuredAgent,
    CodexWebSearchModeError,
    codex_effective_isolated_features,
    codex_isolated_features,
)
from claude_prompt_conformance.agents.judge import JudgementEvidenceUnreadError
from claude_prompt_conformance.clients import (
    ClaudeCandidateAgent,
    CodexJudge,
    candidate_settings,
    canonical_actions,
    parse_claude_response,
)
from claude_prompt_conformance.codex_configuration_session import (
    CodexConfigurationProbeRecordDecodeError,
    CodexConfigurationProbeResponseError,
    CodexConfigurationProbeResultDecodeError,
    CodexConfigurationProbeResultMissingError,
    CodexConfigurationProbeUnexpectedResponseError,
    CodexManagedRequirementsPresentError,
)
from claude_prompt_conformance.errors import ProcessExecutionError
from claude_prompt_conformance.mcp import load_configuration
from claude_prompt_conformance.mcp.evaluator import (
    EVALUATION_BRIEF_TOOL,
    EvaluatorEvidence,
)
from claude_prompt_conformance.models import (
    ClaudeBillingMode,
    ClaudeConfiguration,
    CodexAgentConfiguration,
    CodexConfiguration,
    CodexHostConfiguration,
    FailingJudgementIncompleteError,
    FailureOrigin,
    Fixture,
    InstancePaths,
    IsolationConfiguration,
    JudgedCriterion,
    Judgement,
    JudgementCriteriaEmptyError,
    JudgementEvidenceMissingError,
    JudgementSubject,
    NetworkAccess,
    PassingJudgementInconsistentError,
    ProcessCapabilities,
    ProcessInvocation,
    ProcessOutputRecord,
    ProcessResult,
    PromptVariantConfiguration,
    RuntimeConfiguration,
    SecretFileDescriptor,
)
from claude_prompt_conformance.ports import ProcessSession
from claude_prompt_conformance.process import (
    MissingProcessStatusError,
    ProcessStartError,
)
from claude_prompt_conformance.protocols.claude import (
    CandidateToolResult,
    CandidateToolUse,
    ClaudeContent,
    ClaudeEvent,
    ClaudeMessage,
)
from claude_prompt_conformance.protocols.codex_app_server import (
    CodexAgentsConfiguration,
    CodexBundledSkillsConfiguration,
    CodexCompactionConfiguration,
    CodexEffectiveMcpServer,
    CodexFeatureValue,
    CodexModelRequestConfiguration,
    CodexModelTransport,
    CodexNetworkPermissions,
    CodexPermissionProfile,
    CodexPromptIsolation,
    CodexSkillsConfiguration,
)
from claude_prompt_conformance.protocols.configuration import CriterionInput
from claude_prompt_conformance.protocols.mcp import (
    EvaluatorDescriptor,
    EvaluatorRepository,
    EvaluatorVerification,
)
from claude_prompt_conformance.storage import RetainedPathUnsafeError

from .helpers import (
    FakeInspector,
    FakeInstances,
    FakeOverlay,
    FakeRepositories,
    FakeVerifier,
    codex_identity,
    make_fixture,
)


def effective_permissions(
    configuration: dict[str, object],
    role: str,
) -> dict[str, object]:
    """Model the defaults added by Codex when it serializes a permission profile."""

    profiles = msgspec.convert(
        configuration["permissions"],
        type=dict[str, CodexPermissionProfile],
    )
    profile = profiles[role]
    return {
        role: msgspec.to_builtins(
            CodexPermissionProfile(
                filesystem={"glob_scan_max_depth": None} | profile.filesystem,
                network=profile.network,
            )
        )
    }


def test_codex_configuration_write_failure_stays_inside_typed_boundary(
    tmp_path: Path,
) -> None:
    configuration = runtime_configuration(tmp_path)
    configuration.codex.schema.write_text("{}")
    configuration.codex.tls_certificate_bundle.write_text("certificate")
    instance = FakeInstances().create("candidate", tmp_path / "instances")
    artefacts = instance.root / "artefacts"
    artefacts.mkdir()
    prompt = artefacts / "prompt.md"
    prompt.write_text("Judge the work.\n")
    evidence = artefacts / "evidence.json"
    evidence.write_text("{}")
    codex_home = tmp_path / "host-codex"
    codex_home.mkdir()
    (codex_home / "auth.json").write_text('{"tokens":"credentials"}')
    instance_configuration = instance.judge_state / ".codex" / "config.toml"
    instance_configuration.parent.mkdir()
    instance_configuration.mkdir()
    runner = RecordingJudgeRunner()

    with pytest.raises(CodexInstanceConfigurationWriteError) as raised:
        CodexStructuredAgent(
            configuration,
            runner,
            codex_identity(codex_home),
            CodexHostConfiguration(mcp_servers=()),
        ).run(
            CodexRequest(
                role=CodexRole.EVALUATOR,
                prompt=prompt,
                schema=configuration.codex.schema,
                output=artefacts / "judgement.json",
                events=artefacts / "codex-events.jsonl",
                stderr=artefacts / "codex.stderr",
                control=instance.control / "judge",
                mcp_configuration=evidence,
                environment_path="/bin",
                readable_paths=(),
                root=instance.root,
            ),
            instance,
        )

    assert (
        raised.value,
        runner.invocations,
        tuple(
            path.relative_to(instance.root)
            for path in sorted(instance.root.rglob("*"))
            if path.is_file() and not path.is_symlink()
        ),
    ) == (
        CodexInstanceConfigurationWriteError(
            instance_configuration,
            RetainedPathUnsafeError(instance_configuration.parent),
        ),
        [],
        (
            Path("artefacts/evidence.json"),
            Path("artefacts/judgement.json"),
            Path("artefacts/prompt.md"),
            Path("control/judge/.claude-prompt-conformance-root"),
        ),
    )


@dataclass
class RecordingRunner:
    invocations: list[ProcessInvocation] = field(default_factory=list)
    inputs: list[tuple[object, ...]] = field(default_factory=list)

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        self.invocations.append(invocation)
        invocation.stdout.write_text(
            '{"type":"system","subtype":"init",'
            '"output_style":"Plain technical prose","model":"sonnet"}\n'
            '{"type":"result","is_error":false,"result":"Completed"}\n'
        )
        invocation.stderr.write_text("")
        return ProcessResult(0)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        self.inputs.append(
            tuple(msgspec.json.decode(value) for value in session.initial_input())
        )
        return self.run(invocation)


def serve_evaluation_brief(configuration: Path) -> None:
    """Record the brief request the evaluator MCP server would have served."""

    EvaluatorEvidence(
        msgspec.json.decode(configuration.read_bytes(), type=EvaluatorDescriptor)
    ).record(EVALUATION_BRIEF_TOOL)


@dataclass
class RecordingJudgeRunner:
    serve_brief: bool = True
    invocations: list[ProcessInvocation] = field(default_factory=list)
    inputs: list[tuple[object, ...]] = field(default_factory=list)

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        self.invocations.append(invocation)
        return ProcessResult(99)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        self.invocations.append(invocation)
        self.inputs.append(
            tuple(msgspec.json.decode(value) for value in session.initial_input())
        )
        instance_configuration = tomllib.loads(
            (Path(invocation.environment["CODEX_HOME"]) / "config.toml").read_text()
        )
        conformance = instance_configuration["mcp_servers"]["conformance"]
        initialize = {
            "id": 1,
            "result": {
                "userAgent": "codex_cli_rs/0.146.0",
                "codexHome": invocation.environment["CODEX_HOME"],
                "platformFamily": "unix",
                "platformOs": "macos",
            },
        }
        output = self._send(session, initialize)
        methods: list[object] = []
        for value in self.inputs[-1]:
            if not isinstance(value, dict):
                pytest.fail("app-server client emitted a non-object request")
            methods.append(value.get("method"))
        next_methods = tuple(methods)
        if "config/read" in next_methods:
            responses = (
                {
                    "id": 2,
                    "result": {
                        "config": {
                            "mcp_servers": {
                                "conformance": {
                                    **conformance,
                                    "environment_id": "local",
                                    "tool_timeout_sec": None,
                                },
                                "docs": {"enabled": False},
                                "local.tools": {"enabled": False},
                            },
                            "features": codex_effective_isolated_features(),
                            "project_root_markers": instance_configuration[
                                "project_root_markers"
                            ],
                            "project_doc_max_bytes": instance_configuration[
                                "project_doc_max_bytes"
                            ],
                            "default_permissions": instance_configuration[
                                "default_permissions"
                            ],
                            "permissions": effective_permissions(
                                instance_configuration,
                                "conformance_judge",
                            ),
                            "web_search": instance_configuration["web_search"],
                            "notify": instance_configuration["notify"],
                            "instructions": instance_configuration["instructions"],
                            "developer_instructions": instance_configuration[
                                "developer_instructions"
                            ],
                            "model_instructions_file": None,
                            "personality": instance_configuration["personality"],
                            "agents": {
                                "enabled": False,
                                "max_concurrent_threads_per_session": None,
                                "max_depth": None,
                                "default_subagent_model": None,
                                "default_subagent_reasoning_effort": None,
                                "job_max_runtime_seconds": None,
                                "interrupt_message": None,
                            },
                            "skills": instance_configuration["skills"],
                            "model_provider": instance_configuration["model_provider"],
                            "openai_base_url": instance_configuration[
                                "openai_base_url"
                            ],
                            "chatgpt_base_url": instance_configuration[
                                "chatgpt_base_url"
                            ],
                            "service_tier": instance_configuration["service_tier"],
                            "model_verbosity": instance_configuration[
                                "model_verbosity"
                            ],
                            "model_context_window": instance_configuration[
                                "model_context_window"
                            ],
                            "compact_prompt": instance_configuration["compact_prompt"],
                            "model_auto_compact_token_limit": None,
                            "model_auto_compact_token_limit_scope": None,
                        }
                    },
                },
                {"id": 3, "result": {"requirements": None}},
            )
        else:
            if self.serve_brief:
                serve_evaluation_brief(Path(conformance["args"][0]))
            response = json.dumps(
                {
                    "criteria": [
                        {
                            "id": "works",
                            "passed": True,
                            "reason": "assessment",
                            "evidence": ["diff"],
                        }
                    ],
                    "failureOrigin": "none",
                    "summary": "assessment",
                    "recommendation": "No changes are needed.",
                    "counterfactual": "",
                    "correctedResponse": "",
                    "promptObservations": [],
                }
            )
            responses = (
                {"id": 2, "result": {"type": "chatgptAuthTokens"}},
                {"id": 3, "result": {"thread": {"id": "thread-1"}}},
                {"id": 4, "result": {"turn": {"id": "turn-1"}}},
                {
                    "method": "item/completed",
                    "params": {
                        "threadId": "thread-1",
                        "turnId": "turn-1",
                        "item": {
                            "type": "agentMessage",
                            "id": "message-1",
                            "text": response,
                        },
                    },
                },
                {
                    "method": "turn/completed",
                    "params": {
                        "threadId": "thread-1",
                        "turn": {
                            "id": "turn-1",
                            "status": "completed",
                            "error": None,
                        },
                    },
                },
            )
        for response in responses:
            output += self._send(session, response)
        invocation.stdout.write_bytes(output)
        invocation.stderr.write_text("")
        return ProcessResult(0)

    def _send(self, session: ProcessSession, response: object) -> bytes:
        record = json.dumps(response).encode() + b"\n"
        exchange = session.receive(ProcessOutputRecord(record, 0.0))
        self.inputs.append(
            tuple(msgspec.json.decode(value) for value in exchange.writes)
        )
        return record


@dataclass
class InfrastructureFailingJudgeRunner:
    """Fail at one process-supervisor boundary while preserving the other."""

    stage: "CodexProcessStage"
    failure: ProcessExecutionError
    model_transcript: Path
    delegate: RecordingJudgeRunner = field(default_factory=RecordingJudgeRunner)

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        if self.stage is CodexProcessStage.AGENT:
            raise self.failure
        return self.delegate.run(invocation)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        current_stage = (
            CodexProcessStage.AGENT
            if invocation.stdout == self.model_transcript
            else CodexProcessStage.PROBE
        )
        if self.stage is current_stage:
            raise self.failure
        return self.delegate.run_interactive(invocation, session)


class CodexProcessStage(StrEnum):
    """Externally observable Codex subprocess boundaries."""

    PROBE = "probe"
    AGENT = "agent"


class CodexProbeFailure(StrEnum):
    """Failures exposed by the model-free Codex configuration probe."""

    PROCESS = "process"
    MISSING_RESULT = "missing-result"
    MALFORMED_RECORD = "malformed-record"
    RESPONSE = "response"
    UNEXPECTED_RESPONSE = "unexpected-response"
    MALFORMED_RESULT = "malformed-result"
    REQUIREMENTS = "requirements"
    INVENTORY = "inventory"
    TRANSPORT = "transport"
    FEATURES = "features"
    FEATURES_STRUCTURED = "features-structured"
    AGENTS = "agents"
    SKILLS = "skills"
    PROJECT = "project"
    DEFAULT_PERMISSION = "default-permission"
    WEB_SEARCH = "web-search"
    PROMPT = "prompt"
    PERMISSIONS = "permissions"
    PERMISSIONS_READ = "permissions-read"
    PERMISSIONS_WRITE = "permissions-write"
    TRANSPORT_REDIRECT = "transport-redirect"
    COMPACTION = "compaction"
    MODEL_REQUEST = "model-request"


@dataclass
class FailingCodexProbeRunner:
    failure: CodexProbeFailure
    mcp_configuration: Path
    invocations: list[ProcessInvocation] = field(default_factory=list)
    inputs: list[tuple[object, ...]] = field(default_factory=list)

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        self.invocations.append(invocation)
        return ProcessResult(99)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        self.invocations.append(invocation)
        self.inputs.append(
            tuple(msgspec.json.decode(value) for value in session.initial_input())
        )
        invocation.stdout.write_bytes(b"")
        invocation.stderr.write_text("")

        if self.failure is CodexProbeFailure.PROCESS:
            invocation.stderr.write_text("configuration probe failed\n")
            return ProcessResult(23)

        if self.failure is CodexProbeFailure.MALFORMED_RECORD:
            self._send(session, invocation, b"{")
            return ProcessResult(0)
        if self.failure is CodexProbeFailure.RESPONSE:
            self._send(
                session,
                invocation,
                json.dumps({"id": 1, "error": {"code": -32001}}).encode(),
            )
            return ProcessResult(0)
        if self.failure is CodexProbeFailure.UNEXPECTED_RESPONSE:
            self._send(
                session,
                invocation,
                json.dumps({"id": 2, "result": {}}).encode(),
            )
            return ProcessResult(0)

        self._send(
            session,
            invocation,
            json.dumps(
                {
                    "id": 1,
                    "result": {
                        "userAgent": "codex_cli_rs/0.146.0",
                        "codexHome": invocation.environment["CODEX_HOME"],
                        "platformFamily": "unix",
                        "platformOs": "macos",
                    },
                }
            ).encode(),
        )
        if self.failure is CodexProbeFailure.MISSING_RESULT:
            return ProcessResult(0)

        instance_configuration = tomllib.loads(
            (Path(invocation.environment["CODEX_HOME"]) / "config.toml").read_text()
        )
        permissions = effective_permissions(
            instance_configuration,
            "conformance_judge",
        )
        judge_permissions = cast(dict[str, object], permissions["conformance_judge"])
        if self.failure is CodexProbeFailure.PERMISSIONS:
            cast(dict[str, object], judge_permissions["network"])["enabled"] = True
        if self.failure is CodexProbeFailure.PERMISSIONS_READ:
            cast(dict[str, object], judge_permissions["filesystem"])[":root"] = "read"
        if self.failure is CodexProbeFailure.PERMISSIONS_WRITE:
            cast(dict[str, object], judge_permissions["filesystem"])[":root"] = "write"

        config: dict[str, object] = {}
        if self.failure is not CodexProbeFailure.MALFORMED_RESULT:
            config = {
                "mcp_servers": {
                    "conformance": {
                        "command": (
                            "/wrong/conformance"
                            if self.failure is CodexProbeFailure.TRANSPORT
                            else "/nix/conformance-mcp"
                        ),
                        "args": (
                            []
                            if self.failure is CodexProbeFailure.TRANSPORT
                            else [str(self.mcp_configuration)]
                        ),
                        "environment_id": "local",
                        "enabled": True,
                        "required": True,
                        "tool_timeout_sec": None,
                        "default_tools_approval_mode": "approve",
                    },
                    "docs": {"enabled": self.failure is CodexProbeFailure.INVENTORY},
                },
                "features": codex_effective_isolated_features()
                | (
                    {"multi_agent_v2": {"enabled": True}}
                    if self.failure is CodexProbeFailure.FEATURES_STRUCTURED
                    else {"apps": self.failure is CodexProbeFailure.FEATURES}
                ),
                "agents": {
                    "enabled": self.failure is CodexProbeFailure.AGENTS,
                    "max_concurrent_threads_per_session": None,
                    "max_depth": None,
                    "default_subagent_model": None,
                    "default_subagent_reasoning_effort": None,
                    "job_max_runtime_seconds": None,
                    "interrupt_message": None,
                },
                "skills": (
                    {
                        "bundled": {"enabled": True},
                        "include_instructions": True,
                        "config": [],
                    }
                    if self.failure is CodexProbeFailure.SKILLS
                    else {
                        "bundled": {"enabled": False},
                        "include_instructions": False,
                        "config": [],
                    }
                ),
                "model_provider": "openai",
                "openai_base_url": (
                    "https://redirect.example/v1"
                    if self.failure is CodexProbeFailure.TRANSPORT_REDIRECT
                    else ""
                ),
                "chatgpt_base_url": "https://chatgpt.com/backend-api/",
                "service_tier": (
                    "priority"
                    if self.failure is CodexProbeFailure.MODEL_REQUEST
                    else "fast"
                ),
                "model_verbosity": (
                    "high" if self.failure is CodexProbeFailure.MODEL_REQUEST else "low"
                ),
                "model_context_window": (
                    1024 if self.failure is CodexProbeFailure.MODEL_REQUEST else 272000
                ),
                "compact_prompt": (
                    "Injected compaction instructions"
                    if self.failure is CodexProbeFailure.COMPACTION
                    else ""
                ),
                "model_auto_compact_token_limit": (
                    1 if self.failure is CodexProbeFailure.COMPACTION else None
                ),
                "model_auto_compact_token_limit_scope": (
                    "total" if self.failure is CodexProbeFailure.COMPACTION else None
                ),
                "project_root_markers": (
                    [".git"]
                    if self.failure is CodexProbeFailure.PROJECT
                    else [".claude-prompt-conformance-root"]
                ),
                "project_doc_max_bytes": 0,
                "default_permissions": (
                    "danger-full-access"
                    if self.failure is CodexProbeFailure.DEFAULT_PERMISSION
                    else "conformance_judge"
                ),
                "permissions": permissions,
                "web_search": (
                    "live"
                    if self.failure is CodexProbeFailure.WEB_SEARCH
                    else "disabled"
                ),
                "notify": [],
                "instructions": (
                    "Injected instructions"
                    if self.failure is CodexProbeFailure.PROMPT
                    else ""
                ),
                "developer_instructions": "",
                "model_instructions_file": None,
                "personality": "none",
            }
        self._send(
            session,
            invocation,
            json.dumps({"id": 2, "result": {"config": config}}).encode(),
        )
        self._send(
            session,
            invocation,
            json.dumps(
                {
                    "id": 3,
                    "result": {
                        "requirements": (
                            {"mcpServers": {}}
                            if self.failure is CodexProbeFailure.REQUIREMENTS
                            else None
                        )
                    },
                }
            ).encode(),
        )
        return ProcessResult(0)

    def _send(
        self,
        session: ProcessSession,
        invocation: ProcessInvocation,
        value: bytes,
    ) -> None:
        record = value + b"\n"
        with invocation.stdout.open("ab") as output:
            output.write(record)
        exchange = session.receive(ProcessOutputRecord(record, 0.0))
        self.inputs.append(tuple(msgspec.json.decode(item) for item in exchange.writes))


@dataclass(frozen=True)
class FakeIdentity:
    billing_mode: ClaudeBillingMode

    def environment(self, state: Path) -> dict[str, str]:
        return {"AUTH": "instance-auth"}

    def access_token(self) -> str:
        return "instance-secret"

    def refresh_access_token(self, rejected: str, deadline: float) -> str:
        return "refreshed-instance-secret"


@dataclass(frozen=True)
class NullActivity:
    """Accept activity reports for adapter contract tests."""

    def start_activity(self, identifier: str, description: str) -> None:
        pass

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None:
        pass

    def finish_activity(self, identifier: str, detail: str) -> None:
        pass


def runtime_configuration(tmp_path: Path) -> RuntimeConfiguration:
    settings = tmp_path / "settings.json"
    settings.write_text(
        json.dumps(
            {
                "env": {"CONTROLLED": "yes"},
                "outputStyle": "Plain technical prose",
            }
        )
    )
    candidate_context = tmp_path / "candidate-context"
    candidate_context.mkdir()
    (candidate_context / "manifest.json").write_text("{}")
    (candidate_context / "rules").mkdir()
    (candidate_context / "output-styles").mkdir()
    prompt_source = tmp_path / "prompt-source"
    prompt_source.mkdir()
    (tmp_path / "schema.json").write_text(
        json.dumps(
            {
                "type": "object",
                "properties": {},
                "additionalProperties": True,
            }
        )
    )
    (tmp_path / "proposal-schema.json").write_text("{}")
    (tmp_path / "ca-bundle.crt").write_text("certificate")
    return RuntimeConfiguration(
        fixture_manifest=tmp_path / "fixtures.json",
        run_metadata=tmp_path / "run.json",
        prompt_context=tmp_path / "context.json",
        candidate_context=candidate_context,
        workspace_overlay=tmp_path / "overlay",
        git_program="/nix/git",
        claude=ClaudeConfiguration(
            program="/nix/claude",
            shell="/nix/bash",
            settings=settings,
            model="sonnet",
            effort="medium",
            api_budget_usd="0.75",
            output_style="Plain technical prose",
            oauth_token_url="https://claude.invalid/oauth/token",
            oauth_client_id="claude-client",
        ),
        codex=CodexConfiguration(
            program="/nix/codex",
            mcp_program="/nix/conformance-mcp",
            judge=CodexAgentConfiguration(
                "gpt-5.6-terra", "high", "fast", "low", 272000
            ),
            improver=CodexAgentConfiguration(
                "gpt-5.6-sol", "high", "fast", "low", 272000
            ),
            schema=tmp_path / "schema.json",
            proposal_schema=tmp_path / "proposal-schema.json",
            tls_certificate_bundle=tmp_path / "ca-bundle.crt",
            oauth_token_url="https://codex.invalid/oauth/token",
            oauth_client_id="codex-client",
        ),
        isolation=IsolationConfiguration("darwin", "/usr/bin/sandbox-exec"),
        variant=PromptVariantConfiguration(
            "/nix/nix",
            tmp_path / "nixpkgs",
            tmp_path / "variant.nix",
            tmp_path / "prompt-environment.nix",
            prompt_source,
        ),
        source=tmp_path / "configuration.json",
    )


def isolated_codex_request(
    tmp_path: Path,
) -> tuple[
    RuntimeConfiguration,
    InstancePaths,
    Path,
    CodexRequest,
]:
    """Create the filesystem inputs for one direct structured-agent test."""

    configuration = runtime_configuration(tmp_path)
    configuration.codex.schema.write_text("{}")
    configuration.codex.tls_certificate_bundle.write_text("certificate")
    instance = FakeInstances().create("candidate", tmp_path / "instances")
    artefacts = instance.root / "artefacts"
    artefacts.mkdir()
    prompt = artefacts / "prompt.md"
    prompt.write_text("Judge the work.\n")
    mcp_configuration = artefacts / "evidence.json"
    mcp_configuration.write_text("{}")
    codex_home = tmp_path / "host-codex"
    return (
        configuration,
        instance,
        codex_home,
        CodexRequest(
            role=CodexRole.EVALUATOR,
            prompt=prompt,
            schema=configuration.codex.schema,
            output=artefacts / "judgement.json",
            events=artefacts / "codex-events.jsonl",
            stderr=artefacts / "codex.stderr",
            control=instance.control / "judge",
            mcp_configuration=mcp_configuration,
            environment_path="/bin",
            readable_paths=(),
            root=instance.root,
        ),
    )


@pytest.mark.parametrize("stage", tuple(CodexProcessStage))
@pytest.mark.parametrize(
    "failure",
    (
        ProcessStartError(("/nix/codex", "app-server", "--stdio"), 2, "/nix/codex"),
        MissingProcessStatusError(("/nix/codex", "app-server", "--stdio")),
    ),
)
def test_codex_process_infrastructure_failures_stay_inside_the_typed_boundary(
    tmp_path: Path,
    stage: CodexProcessStage,
    failure: ProcessExecutionError,
) -> None:
    configuration, instance, codex_home, request = isolated_codex_request(tmp_path)
    expected: Exception
    if stage is CodexProcessStage.PROBE:
        expected = CodexConfigurationProbeExecutionError(failure)
    else:
        expected = CodexAgentExecutionError("conformance_judge", failure)

    with pytest.raises(type(expected)) as raised:
        CodexStructuredAgent(
            configuration,
            InfrastructureFailingJudgeRunner(stage, failure, request.events),
            codex_identity(codex_home),
            CodexHostConfiguration(mcp_servers=("docs", "local.tools")),
        ).run(request, instance)

    assert (
        raised.value,
        request.output.read_bytes(),
        (request.control / ".claude-prompt-conformance-root").read_bytes(),
    ) == (
        expected,
        b"",
        b"",
    )


def successful_events() -> tuple[ClaudeEvent, ...]:
    return (
        ClaudeEvent(
            type="system",
            subtype="init",
            output_style="Plain technical prose",
            model="sonnet",
        ),
        ClaudeEvent(
            type="result",
            subtype="success",
            result="Completed response",
        ),
    )


def test_parse_claude_response_requires_the_configured_style() -> None:
    assert (
        parse_claude_response(successful_events(), "Plain technical prose", "sonnet")
        == "Completed response"
    )


@pytest.mark.parametrize(
    ("billing_mode", "budget_arguments"),
    [
        (ClaudeBillingMode.SUBSCRIPTION, ()),
        (ClaudeBillingMode.API, ("--max-budget-usd", "0.75")),
    ],
)
def test_claude_candidate_applies_budgets_only_to_api_usage(
    tmp_path: Path,
    billing_mode: ClaudeBillingMode,
    budget_arguments: tuple[str, ...],
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    instance = FakeInstances().create("candidate", tmp_path)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    runner = RecordingRunner()
    configuration = runtime_configuration(tmp_path)
    candidate = ClaudeCandidateAgent(configuration, runner, FakeIdentity(billing_mode))

    result = candidate.run(fixture, instance, artefacts, NullActivity())

    assert (
        result,
        runner.invocations,
        runner.inputs,
        json.loads((instance.control / "candidate-settings.json").read_text()),
        msgspec.json.decode((artefacts / "candidate-actions.json").read_bytes()),
        (
            (instance.candidate_state / ".claude" / "rules").readlink(),
            (instance.candidate_state / ".claude" / "output-styles").readlink(),
            json.loads((instance.control / "candidate-mcp.json").read_text()),
        ),
    ) == (
        type(result)(
            "Completed",
            artefacts / "claude-events.jsonl",
            artefacts / "candidate-actions.json",
        ),
        [
            ProcessInvocation(
                command=(
                    "/nix/claude",
                    "--model",
                    "sonnet",
                    "--effort",
                    "medium",
                    "--settings",
                    str(instance.control / "candidate-settings.json"),
                    "--setting-sources",
                    "user",
                    "--mcp-config",
                    str(instance.control / "candidate-mcp.json"),
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
                ),
                cwd=instance.workspace,
                environment={
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "PATH": "/bin",
                    "TZ": "UTC",
                    "AUTH": "instance-auth",
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                    "CLAUDE_CODE_ENTRYPOINT": "local-agent",
                    "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH": "1",
                    "CLAUDE_CODE_SHELL": "/nix/bash",
                    "CLAUDE_CODE_TMPDIR": str(instance.candidate_temp),
                    "GIT_CONFIG_GLOBAL": str(instance.control / "candidate-gitconfig"),
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_SSH_COMMAND": "false",
                    "GIT_TERMINAL_PROMPT": "0",
                    "TMPDIR": str(instance.candidate_temp),
                    "XDG_CACHE_HOME": str(instance.candidate_cache),
                    "XDG_STATE_HOME": str(instance.candidate_state),
                },
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
                stdout=artefacts / "claude-events.jsonl",
                stderr=artefacts / "claude.stderr",
                secrets=(
                    SecretFileDescriptor(
                        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
                        b"instance-secret",
                    ),
                ),
            )
        ],
        [
            (
                {
                    "type": "control_request",
                    "request_id": "prompt-conformance-initialize",
                    "request": {"subtype": "initialize", "hooks": None},
                },
                {
                    "type": "user",
                    "session_id": "",
                    "message": {
                        "role": "user",
                        "content": fixture.task.read_text(),
                    },
                    "parent_tool_use_id": None,
                },
            )
        ],
        {
            "env": {
                "CONTROLLED": "yes",
                "PATH": "/bin",
                "TMPDIR": str(instance.candidate_temp),
            },
            "outputStyle": "Plain technical prose",
        },
        [],
        (
            configuration.candidate_context / "rules",
            configuration.candidate_context / "output-styles",
            {"mcpServers": {}},
        ),
    )


def test_candidate_settings_preserve_the_nix_assembled_configuration(
    tmp_path: Path,
) -> None:
    configuration = runtime_configuration(tmp_path)

    assert candidate_settings(
        configuration.claude.settings,
        "/nix/tools",
        tmp_path / "private-tmp",
    ) == {
        "env": {
            "CONTROLLED": "yes",
            "PATH": "/nix/tools",
            "TMPDIR": str(tmp_path / "private-tmp"),
        },
        "outputStyle": "Plain technical prose",
    }


def test_parse_claude_response_reports_the_style_mismatch_structurally() -> None:
    events = (
        ClaudeEvent(
            type="system", subtype="init", output_style="default", model="sonnet"
        ),
        ClaudeEvent(type="result", result="response"),
    )

    with pytest.raises(CandidateOutputStyleError) as raised:
        parse_claude_response(events, "Plain technical prose", "sonnet")

    assert raised.value == CandidateOutputStyleError("default", "Plain technical prose")


def test_parse_claude_response_reports_the_effective_model_mismatch() -> None:
    events = (
        ClaudeEvent(
            type="system",
            subtype="init",
            output_style="Plain technical prose",
            model="unexpected",
        ),
        ClaudeEvent(type="result", result="response"),
    )

    with pytest.raises(CandidateModelError) as raised:
        parse_claude_response(events, "Plain technical prose", "claude-opus-5")

    assert raised.value == CandidateModelError("unexpected", "claude-opus-5")


def test_canonical_actions_are_a_complete_typed_ledger() -> None:
    events = (
        ClaudeEvent(
            type="assistant",
            message=ClaudeMessage(
                content=(
                    ClaudeContent(
                        type="tool_use",
                        id="call-1",
                        name="Read",
                        input={"file_path": "README.md"},
                    ),
                )
            ),
        ),
        ClaudeEvent(
            type="user",
            message=ClaudeMessage(
                content=(
                    ClaudeContent(
                        type="tool_result",
                        tool_use_id="call-1",
                        content="contents",
                    ),
                )
            ),
        ),
    )

    assert canonical_actions(events) == (
        CandidateToolUse("call-1", "Read", {"file_path": "README.md"}),
        CandidateToolResult("call-1", "contents", False),
    )


def test_transcripts_with_a_permission_denial_still_decode(tmp_path: Path) -> None:
    transcript = tmp_path / "claude-events.jsonl"
    transcript.write_text(
        json.dumps(
            {
                "type": "system",
                "subtype": "permission_denied",
                "tool_name": "Bash",
                "tool_use_id": "call-1",
                "message": "Dangerous rm operation detected: 'workspace/*'",
            }
        )
        + "\n"
        + json.dumps({"type": "result", "result": "response"})
        + "\n"
    )

    events = read_json_lines(transcript)

    assert (events, canonical_actions(events)) == (
        (
            ClaudeEvent(
                type="system",
                subtype="permission_denied",
                message="Dangerous rm operation detected: 'workspace/*'",
            ),
            ClaudeEvent(type="result", result="response"),
        ),
        (),
    )


@pytest.mark.parametrize(
    ("contents", "expected"),
    [
        (
            {
                "criteria": [],
                "failureOrigin": "environment",
                "summary": "Evaluation could not be performed.",
                "recommendation": "Enable the evidence tools.",
                "counterfactual": "",
                "correctedResponse": "",
                "promptObservations": [],
            },
            JudgementCriteriaEmptyError(),
        ),
        (
            {
                "criteria": [
                    {"id": "works", "passed": True, "reason": "yes", "evidence": []}
                ],
                "failureOrigin": "none",
                "summary": "done",
                "recommendation": "No change.",
                "counterfactual": "",
                "correctedResponse": "",
                "promptObservations": [],
            },
            JudgementEvidenceMissingError("works"),
        ),
        (
            {
                "criteria": [
                    {
                        "id": "works",
                        "passed": True,
                        "reason": "yes",
                        "evidence": ["diff"],
                    }
                ],
                "failureOrigin": "prompt",
                "summary": "done",
                "recommendation": "No change.",
                "counterfactual": "patch",
                "correctedResponse": "response",
                "promptObservations": [],
            },
            PassingJudgementInconsistentError(),
        ),
        (
            {
                "criteria": [
                    {
                        "id": "works",
                        "passed": False,
                        "reason": "no",
                        "evidence": ["diff"],
                    }
                ],
                "failureOrigin": "none",
                "summary": "failed",
                "recommendation": "",
                "counterfactual": "",
                "correctedResponse": "",
                "promptObservations": [],
            },
            FailingJudgementIncompleteError(),
        ),
    ],
)
def test_judgement_rejects_semantically_inconsistent_results(
    tmp_path: Path,
    contents: dict[str, object],
    expected: Exception,
) -> None:
    source = tmp_path / "judgement.json"
    source.write_text(json.dumps(contents))

    with pytest.raises(type(expected)) as raised:
        Judgement.from_file(source)

    assert raised.value == expected


@dataclass(frozen=True)
class JudgeInputs:
    """Everything one prepared fixture contributes to a judge assessment."""

    fixture: Fixture
    instance: InstancePaths
    artefacts: Path
    configuration: RuntimeConfiguration
    subject: JudgementSubject


def judge_inputs(tmp_path: Path) -> JudgeInputs:
    """Prepare one materialised candidate subject ready for assessment."""

    fixture = make_fixture(tmp_path / "fixtures")
    instance = FakeInstances().create("candidate", tmp_path)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    FakeRepositories().materialise(
        fixture.repository,
        instance.workspace,
        instance.control,
        fixture.environment_path,
        fixture.repository.revision,
    )
    FakeOverlay().install(instance.workspace)
    evidence = FakeInspector().inspect(
        instance.workspace, "base", artefacts, fixture.environment_path
    )
    verification = FakeVerifier().verify(fixture, instance, artefacts)
    trace = artefacts / "trace.json"
    trace.write_bytes(msgspec.json.encode((CandidateToolUse("1", "Read", {}),)))
    return JudgeInputs(
        fixture=fixture,
        instance=instance,
        artefacts=artefacts,
        configuration=runtime_configuration(tmp_path),
        subject=JudgementSubject(
            "candidate",
            instance.workspace,
            "final response",
            trace,
            evidence,
            verification,
        ),
    )


def test_codex_judge_rejects_a_judgement_reached_without_the_brief(
    tmp_path: Path,
) -> None:
    inputs = judge_inputs(tmp_path)
    access_record = inputs.instance.control / "judge" / "tool-calls-candidate.txt"

    with pytest.raises(JudgementEvidenceUnreadError) as raised:
        CodexJudge(
            inputs.configuration,
            RecordingJudgeRunner(serve_brief=False),
            codex_identity(tmp_path / "host-codex"),
            CodexHostConfiguration(mcp_servers=("conformance", "docs", "local.tools")),
        ).assess(
            inputs.fixture,
            inputs.subject,
            inputs.instance,
            inputs.artefacts,
        )

    assert (raised.value, access_record.read_text()) == (
        JudgementEvidenceUnreadError(access_record),
        "",
    )


def test_codex_judge_uses_bespoke_mcp_and_shared_auth(
    tmp_path: Path,
) -> None:
    inputs = judge_inputs(tmp_path)
    fixture = inputs.fixture
    instance = inputs.instance
    artefacts = inputs.artefacts
    configuration = inputs.configuration
    subject = inputs.subject
    codex_home = tmp_path / "host-codex"
    auth = codex_home / "auth.json"
    identity = codex_identity(codex_home)
    host_document = auth.read_text()
    runner = RecordingJudgeRunner()

    result = CodexJudge(
        configuration,
        runner,
        identity,
        CodexHostConfiguration(mcp_servers=("conformance", "docs", "local.tools")),
    ).assess(fixture, subject, instance, artefacts)

    control = instance.control / "judge"
    access_record = control / "tool-calls-candidate.txt"
    mcp_configuration = artefacts / "judge-candidate-mcp.json"
    response = artefacts / "subject-candidate-response.md"
    expected_environment = {
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/bin",
        "TZ": "UTC",
        "CODEX_HOME": str(instance.judge_state / ".codex"),
        "HOME": str(instance.judge_state),
        "SSL_CERT_FILE": str(tmp_path / "ca-bundle.crt"),
        "TMPDIR": str(instance.judge_temp),
        "XDG_CACHE_HOME": str(instance.judge_cache),
    }
    expected_capabilities = ProcessCapabilities(
        writable_paths=(
            instance.judge_state,
            instance.judge_cache,
            instance.judge_temp,
            control,
        ),
        readable_paths=(
            instance.workspace,
            artefacts,
            configuration.candidate_context,
            fixture.task,
            tmp_path / "schema.json",
            mcp_configuration,
            tmp_path / "ca-bundle.crt",
        ),
        network=NetworkAccess.PUBLIC,
    )
    initialize_request = {
        "id": 1,
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "prompt-conformance",
                "title": "Prompt conformance",
                "version": "1",
            },
            "capabilities": {"experimentalApi": True},
        },
    }
    assert (
        result,
        load_configuration(mcp_configuration),
        access_record.read_text(),
        runner.invocations,
        runner.inputs,
        tomllib.loads((instance.judge_state / ".codex" / "config.toml").read_text()),
        (control / ".claude-prompt-conformance-root").read_text(),
        auth.read_text(),
        (instance.judge_state / ".codex" / "auth.json").exists(),
    ) == (
        Judgement(
            criteria=(JudgedCriterion("works", True, "assessment", ("diff",)),),
            failure_origin=FailureOrigin.NONE,
            summary="assessment",
            recommendation="No changes are needed.",
            counterfactual="",
            corrected_response="",
            prompt_observations=(),
        ),
        EvaluatorDescriptor(
            task=str(fixture.task),
            task_kind="author",
            criteria=(CriterionInput("works", "outcome", "The fix works.", True),),
            prompt_root=str(configuration.candidate_context),
            response=str(response),
            actions=str(subject.trace),
            workspace=str(instance.workspace),
            repository=EvaluatorRepository(
                url="https://example.invalid/repository.git",
                base_revision="base",
                head_revision="base",
                status=" M file",
                changed_files=("file",),
                diff=str(artefacts / "diff.patch"),
                commits=str(artefacts / "commits.txt"),
            ),
            verification=(
                EvaluatorVerification(
                    name="check",
                    command=("check",),
                    kind="gate",
                    expected_return_code=0,
                    return_code=0,
                    stdout=str(artefacts / "check.stdout"),
                    stderr=str(artefacts / "check.stderr"),
                ),
            ),
            access_record=str(access_record),
        ),
        "get_evaluation_brief\n",
        [
            ProcessInvocation(
                command=("/nix/codex", "app-server", "--stdio"),
                cwd=control,
                environment=expected_environment,
                capabilities=expected_capabilities,
                stdout=artefacts / "codex-candidate-events-config-read.jsonl",
                stderr=artefacts / "codex-candidate-config-read.stderr",
            ),
            ProcessInvocation(
                command=("/nix/codex", "app-server", "--stdio"),
                cwd=control,
                environment=expected_environment,
                capabilities=expected_capabilities,
                stdout=artefacts / "codex-candidate-events.jsonl",
                stderr=artefacts / "codex-candidate.stderr",
            ),
        ],
        [
            (initialize_request,),
            (
                {"method": "initialized", "params": {}},
                {
                    "id": 2,
                    "method": "config/read",
                    "params": {
                        "includeLayers": True,
                        "cwd": str(control),
                    },
                },
            ),
            (
                {
                    "id": 3,
                    "method": "configRequirements/read",
                },
            ),
            (),
            (initialize_request,),
            (
                {"method": "initialized", "params": {}},
                {
                    "id": 2,
                    "method": "account/login/start",
                    "params": {
                        "type": "chatgptAuthTokens",
                        "accessToken": "access-token",
                        "chatgptAccountId": "account-id",
                        "chatgptPlanType": None,
                    },
                },
            ),
            (
                {
                    "id": 3,
                    "method": "thread/start",
                    "params": {
                        "model": "gpt-5.6-terra",
                        "serviceTier": "fast",
                        "cwd": str(control),
                        "permissions": "conformance_judge",
                        "baseInstructions": "",
                        "developerInstructions": "",
                        "personality": "none",
                        "ephemeral": True,
                    },
                },
            ),
            (
                {
                    "id": 4,
                    "method": "turn/start",
                    "params": {
                        "threadId": "thread-1",
                        "input": [
                            {
                                "type": "text",
                                "text": (
                                    artefacts / "judge-candidate-prompt.md"
                                ).read_text(),
                                "textElements": [],
                            }
                        ],
                        "effort": "high",
                        "outputSchema": json.loads(
                            configuration.codex.schema.read_text()
                        ),
                    },
                },
            ),
            (),
            (),
            (),
        ],
        {
            "model_reasoning_effort": "high",
            "service_tier": "fast",
            "model_verbosity": "low",
            "model_context_window": 272000,
            "cli_auth_credentials_store": "ephemeral",
            "project_doc_max_bytes": 0,
            "project_root_markers": [".claude-prompt-conformance-root"],
            "web_search": "disabled",
            "notify": [],
            "instructions": "",
            "developer_instructions": "",
            "compact_prompt": "",
            "personality": "none",
            "default_permissions": "conformance_judge",
            "features": codex_isolated_features(),
            "agents": {"enabled": False},
            "skills": {
                "bundled": {"enabled": False},
                "include_instructions": False,
            },
            "model_provider": "openai",
            "openai_base_url": "",
            "chatgpt_base_url": "https://chatgpt.com/backend-api/",
            "mcp_servers": {
                "docs": {"enabled": False},
                "local.tools": {"enabled": False},
                "conformance": {
                    "command": "/nix/conformance-mcp",
                    "args": [str(mcp_configuration)],
                    "required": True,
                    "default_tools_approval_mode": "approve",
                    "enabled": True,
                },
            },
            "permissions": {
                "conformance_judge": {
                    "filesystem": {
                        ":root": "deny",
                    },
                    "network": {"enabled": False},
                }
            },
        },
        "",
        host_document,
        False,
    )


@pytest.mark.parametrize("failure", tuple(CodexProbeFailure))
def test_codex_configuration_probe_fails_before_the_model_process(
    tmp_path: Path,
    failure: CodexProbeFailure,
) -> None:
    configuration = runtime_configuration(tmp_path)
    configuration.codex.schema.write_text("{}")
    configuration.codex.tls_certificate_bundle.write_text("certificate")
    instance = FakeInstances().create("candidate", tmp_path)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    prompt = artefacts / "prompt.md"
    prompt.write_text("Judge the work.\n")
    mcp_configuration = artefacts / "evidence.json"
    mcp_configuration.write_text("{}")
    output = artefacts / "judgement.json"
    events = artefacts / "codex-events.jsonl"
    stderr = artefacts / "codex.stderr"
    control = instance.control / "judge"
    codex_home = tmp_path / "host-codex"
    identity = codex_identity(codex_home)
    runner = FailingCodexProbeRunner(failure, mcp_configuration)
    request = CodexRequest(
        role=CodexRole.EVALUATOR,
        prompt=prompt,
        schema=configuration.codex.schema,
        output=output,
        events=events,
        stderr=stderr,
        control=control,
        mcp_configuration=mcp_configuration,
        environment_path="/bin",
        readable_paths=(),
        root=artefacts,
    )
    transcript = artefacts / "codex-events-config-read.jsonl"
    probe_stderr = artefacts / "codex-config-read.stderr"
    expected_error: Exception
    if failure is CodexProbeFailure.PROCESS:
        expected_error = CodexConfigurationProbeProcessError(23, probe_stderr)
    elif failure is CodexProbeFailure.MISSING_RESULT:
        expected_error = CodexConfigurationProbeResultMissingError(transcript)
    elif failure is CodexProbeFailure.MALFORMED_RECORD:
        expected_error = CodexConfigurationProbeRecordDecodeError(transcript)
    elif failure is CodexProbeFailure.RESPONSE:
        expected_error = CodexConfigurationProbeResponseError(1, -32001)
    elif failure is CodexProbeFailure.UNEXPECTED_RESPONSE:
        expected_error = CodexConfigurationProbeUnexpectedResponseError(1, 2)
    elif failure is CodexProbeFailure.MALFORMED_RESULT:
        expected_error = CodexConfigurationProbeResultDecodeError(transcript)
    elif failure is CodexProbeFailure.REQUIREMENTS:
        expected_error = CodexManagedRequirementsPresentError(transcript)
    elif failure is CodexProbeFailure.INVENTORY:
        expected_error = CodexEffectiveMcpInventoryError(
            (("conformance", True), ("docs", True)),
            (("conformance", True), ("docs", False)),
        )
    elif failure is CodexProbeFailure.TRANSPORT:
        expected_error = CodexConformanceMcpTransportError(
            CodexEffectiveMcpServer(
                command="/wrong/conformance",
                enabled=True,
                required=True,
                default_tools_approval_mode="approve",
            ),
            CodexEffectiveMcpServer(
                command="/nix/conformance-mcp",
                args=(str(mcp_configuration),),
                enabled=True,
                required=True,
                default_tools_approval_mode="approve",
            ),
        )
    elif failure is CodexProbeFailure.FEATURES:
        actual_features: dict[str, CodexFeatureValue] = dict(
            codex_effective_isolated_features()
        )
        actual_features["apps"] = True
        expected_error = CodexFeatureIsolationError(
            actual_features,
            codex_effective_isolated_features(),
        )
    elif failure is CodexProbeFailure.FEATURES_STRUCTURED:
        actual_features = dict(codex_effective_isolated_features())
        actual_features["multi_agent_v2"] = {"enabled": True}
        expected_error = CodexFeatureIsolationError(
            actual_features,
            codex_effective_isolated_features(),
        )
    elif failure is CodexProbeFailure.AGENTS:
        expected_error = CodexAgentsIsolationError(
            CodexAgentsConfiguration(enabled=True),
            CodexAgentsConfiguration(enabled=False),
        )
    elif failure is CodexProbeFailure.SKILLS:
        expected_error = CodexSkillsIsolationError(
            CodexSkillsConfiguration(
                bundled=CodexBundledSkillsConfiguration(enabled=True),
                include_instructions=True,
            ),
            CodexSkillsConfiguration(
                bundled=CodexBundledSkillsConfiguration(enabled=False),
                include_instructions=False,
            ),
        )
    elif failure is CodexProbeFailure.PROJECT:
        expected_error = CodexProjectIsolationError(
            ((".git",), 0),
            ((".claude-prompt-conformance-root",), 0),
        )
    elif failure is CodexProbeFailure.DEFAULT_PERMISSION:
        expected_error = CodexDefaultPermissionProfileError(
            "danger-full-access",
            "conformance_judge",
        )
    elif failure is CodexProbeFailure.WEB_SEARCH:
        expected_error = CodexWebSearchModeError("live")
    elif failure is CodexProbeFailure.PROMPT:
        expected_error = CodexPromptIsolationError(
            CodexPromptIsolation(
                notify=(),
                instructions="Injected instructions",
                developer_instructions="",
                model_instructions_file=None,
                personality="none",
            ),
            CodexPromptIsolation(
                notify=(),
                instructions="",
                developer_instructions="",
                model_instructions_file=None,
                personality="none",
            ),
        )
    elif failure in (
        CodexProbeFailure.PERMISSIONS,
        CodexProbeFailure.PERMISSIONS_READ,
        CodexProbeFailure.PERMISSIONS_WRITE,
    ):
        filesystem = {
            "glob_scan_max_depth": None,
            ":root": "deny",
        }
        if failure is CodexProbeFailure.PERMISSIONS_READ:
            filesystem[":root"] = "read"
        if failure is CodexProbeFailure.PERMISSIONS_WRITE:
            filesystem[":root"] = "write"
        expected_error = CodexPermissionProfileError(
            CodexPermissionProfile(
                filesystem=filesystem,
                network=CodexNetworkPermissions(
                    enabled=failure is CodexProbeFailure.PERMISSIONS
                ),
            ),
            CodexPermissionProfile(
                filesystem={
                    "glob_scan_max_depth": None,
                    ":root": "deny",
                },
                network=CodexNetworkPermissions(enabled=False),
            ),
        )
    elif failure is CodexProbeFailure.TRANSPORT_REDIRECT:
        expected_error = CodexModelTransportError(
            CodexModelTransport(
                provider="openai",
                openai_base_url="https://redirect.example/v1",
                chatgpt_base_url="https://chatgpt.com/backend-api/",
            ),
            CodexModelTransport(
                provider="openai",
                openai_base_url="",
                chatgpt_base_url="https://chatgpt.com/backend-api/",
            ),
        )
    elif failure is CodexProbeFailure.COMPACTION:
        expected_error = CodexCompactionIsolationError(
            CodexCompactionConfiguration(
                "Injected compaction instructions",
                1,
                "total",
            ),
            CodexCompactionConfiguration("", None, None),
        )
    else:
        expected_error = CodexModelRequestIsolationError(
            CodexModelRequestConfiguration("priority", "high", 1024),
            CodexModelRequestConfiguration("fast", "low", 272000),
        )

    with pytest.raises(type(expected_error)) as raised:
        CodexStructuredAgent(
            configuration,
            runner,
            identity,
            CodexHostConfiguration(mcp_servers=("conformance", "docs")),
        ).run(request, instance)

    assert (
        raised.value,
        runner.invocations,
        runner.inputs,
        probe_stderr.read_text(),
        output.read_bytes(),
        (control / ".claude-prompt-conformance-root").read_bytes(),
    ) == (
        expected_error,
        [
            ProcessInvocation(
                command=("/nix/codex", "app-server", "--stdio"),
                cwd=control,
                environment={
                    "CODEX_HOME": str(instance.judge_state / ".codex"),
                    "HOME": str(instance.judge_state),
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "PATH": "/bin",
                    "SSL_CERT_FILE": str(configuration.codex.tls_certificate_bundle),
                    "TMPDIR": str(instance.judge_temp),
                    "TZ": "UTC",
                    "XDG_CACHE_HOME": str(instance.judge_cache),
                },
                capabilities=ProcessCapabilities(
                    writable_paths=(
                        instance.judge_state,
                        instance.judge_cache,
                        instance.judge_temp,
                        control,
                    ),
                    readable_paths=(
                        configuration.codex.schema,
                        mcp_configuration,
                        configuration.codex.tls_certificate_bundle,
                    ),
                    network=NetworkAccess.PUBLIC,
                ),
                stdout=transcript,
                stderr=probe_stderr,
            )
        ],
        [
            (
                {
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {
                            "name": "prompt-conformance",
                            "title": "Prompt conformance",
                            "version": "1",
                        },
                        "capabilities": {"experimentalApi": True},
                    },
                },
            ),
            *(
                []
                if failure
                in (
                    CodexProbeFailure.PROCESS,
                    CodexProbeFailure.MALFORMED_RECORD,
                    CodexProbeFailure.RESPONSE,
                    CodexProbeFailure.UNEXPECTED_RESPONSE,
                )
                else [
                    (
                        {"method": "initialized", "params": {}},
                        {
                            "id": 2,
                            "method": "config/read",
                            "params": {
                                "includeLayers": True,
                                "cwd": str(control),
                            },
                        },
                    )
                ]
            ),
            *(
                [
                    (
                        {
                            "id": 3,
                            "method": "configRequirements/read",
                        },
                    )
                ]
                if failure
                in (
                    CodexProbeFailure.REQUIREMENTS,
                    CodexProbeFailure.INVENTORY,
                    CodexProbeFailure.TRANSPORT,
                    CodexProbeFailure.FEATURES,
                    CodexProbeFailure.FEATURES_STRUCTURED,
                    CodexProbeFailure.AGENTS,
                    CodexProbeFailure.SKILLS,
                    CodexProbeFailure.PROJECT,
                    CodexProbeFailure.DEFAULT_PERMISSION,
                    CodexProbeFailure.WEB_SEARCH,
                    CodexProbeFailure.PROMPT,
                    CodexProbeFailure.PERMISSIONS,
                    CodexProbeFailure.PERMISSIONS_READ,
                    CodexProbeFailure.PERMISSIONS_WRITE,
                    CodexProbeFailure.TRANSPORT_REDIRECT,
                    CodexProbeFailure.COMPACTION,
                    CodexProbeFailure.MODEL_REQUEST,
                )
                else []
            ),
            *(
                [()]
                if failure
                in (
                    CodexProbeFailure.INVENTORY,
                    CodexProbeFailure.TRANSPORT,
                    CodexProbeFailure.FEATURES,
                    CodexProbeFailure.FEATURES_STRUCTURED,
                    CodexProbeFailure.AGENTS,
                    CodexProbeFailure.SKILLS,
                    CodexProbeFailure.PROJECT,
                    CodexProbeFailure.DEFAULT_PERMISSION,
                    CodexProbeFailure.WEB_SEARCH,
                    CodexProbeFailure.PROMPT,
                    CodexProbeFailure.PERMISSIONS,
                    CodexProbeFailure.PERMISSIONS_READ,
                    CodexProbeFailure.PERMISSIONS_WRITE,
                    CodexProbeFailure.TRANSPORT_REDIRECT,
                    CodexProbeFailure.COMPACTION,
                    CodexProbeFailure.MODEL_REQUEST,
                )
                else []
            ),
        ],
        (
            "configuration probe failed\n"
            if failure is CodexProbeFailure.PROCESS
            else ""
        ),
        b"",
        b"",
    )
