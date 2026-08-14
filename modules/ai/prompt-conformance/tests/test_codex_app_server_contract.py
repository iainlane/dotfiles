import os
import shutil
import tomllib
from dataclasses import dataclass
from pathlib import Path

import msgspec
import pytest
import tomli_w

from claude_prompt_conformance.agents.codex import (
    CodexRequest,
    CodexRole,
    codex_effective_isolated_features,
    codex_instance_configuration,
)
from claude_prompt_conformance.codex_configuration_session import (
    CodexConfigurationSession,
)
from claude_prompt_conformance.codex_rpc import (
    CodexRpcEmptyParameters,
    CodexRpcNotification,
    CodexRpcRequest,
    codex_initialize_request,
    codex_rpc_line,
)
from claude_prompt_conformance.models import (
    CodexAgentConfiguration,
    CodexHostConfiguration,
    NetworkAccess,
    ProcessCapabilities,
    ProcessExchange,
    ProcessInvocation,
    ProcessOutputRecord,
    ProcessResult,
)
from claude_prompt_conformance.ports import ProcessSession
from claude_prompt_conformance.process import ProcessSupervisor
from claude_prompt_conformance.protocols.codex_app_server import (
    CodexAgentsConfiguration,
    CodexBundledSkillsConfiguration,
    CodexCompactionConfiguration,
    CodexEffectiveMcpServer,
    CodexExternalLoginParameters,
    CodexExternalLoginResponse,
    CodexExternalLoginResult,
    CodexModelRequestConfiguration,
    CodexModelTransport,
    CodexNetworkPermissions,
    CodexPermissionProfile,
    CodexSkillsConfiguration,
)
from claude_prompt_conformance.workspace import clean_environment

from .helpers import unsigned_access_token


@dataclass
class ExternalLoginContractSession(ProcessSession):
    """Install fake external auth, then close without starting a model turn."""

    access_token: str
    response: CodexExternalLoginResponse | None = None

    def initial_input(self) -> tuple[bytes, ...]:
        return (codex_initialize_request(1),)

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        envelope = msgspec.json.decode(record.value, type=dict[str, object])
        if envelope.get("method") is not None:
            return ProcessExchange()
        if envelope.get("id") == 1:
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
                            id=2,
                            method="account/login/start",
                            params=CodexExternalLoginParameters(
                                access_token=self.access_token,
                                chatgpt_account_id="account-1",
                                chatgpt_plan_type="pro",
                            ),
                        )
                    ),
                )
            )
        self.response = msgspec.json.decode(
            record.value,
            type=CodexExternalLoginResponse,
        )
        return ProcessExchange(close_input=True)


@pytest.mark.host_integration
def test_pinned_codex_app_server_reports_the_protocol_contract(
    tmp_path: Path,
) -> None:
    """Exercise the protocol schema against the Codex executable packaged by Nix."""

    codex = shutil.which("codex")
    if codex is None:
        pytest.fail("the pinned Codex executable is required for this contract test")

    codex_home = tmp_path / "codex-home"
    codex_home.mkdir()
    control = tmp_path / "control"
    control.mkdir()
    (control / ".claude-prompt-conformance-root").touch()
    evidence = tmp_path / "evidence.json"
    evidence.write_text("{}")
    request = CodexRequest(
        role=CodexRole.EVALUATOR,
        prompt=tmp_path / "prompt.md",
        schema=tmp_path / "schema.json",
        output=tmp_path / "output.json",
        events=tmp_path / "events.jsonl",
        stderr=tmp_path / "stderr",
        control=control,
        mcp_configuration=evidence,
        environment_path=os.environ["PATH"],
        readable_paths=(),
        root=tmp_path,
    )
    configuration = codex_instance_configuration(
        request,
        CodexAgentConfiguration("gpt-5.6-terra", "high", "fast", "low", 272000),
        "/nix/conformance-mcp",
        CodexHostConfiguration(mcp_servers=()),
    )
    (codex_home / "config.toml").write_text(tomli_w.dumps(configuration))
    transcript = tmp_path / "config-read.jsonl"
    session = CodexConfigurationSession(control, transcript)
    invocation = ProcessInvocation(
        command=(codex, "app-server", "--stdio"),
        cwd=control,
        environment=clean_environment(os.environ["PATH"])
        | {"CODEX_HOME": str(codex_home), "HOME": str(tmp_path)},
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=transcript,
        stderr=tmp_path / "config-read.stderr",
    )

    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        session,
    )
    effective = session.configuration
    if effective is None:
        pytest.fail("Codex closed without returning its effective configuration")
    login_session = ExternalLoginContractSession(unsigned_access_token())
    login_result = ProcessSupervisor().run_interactive(
        ProcessInvocation(
            command=(codex, "app-server", "--stdio"),
            cwd=control,
            environment=invocation.environment,
            capabilities=invocation.capabilities,
            stdout=tmp_path / "external-login.jsonl",
            stderr=tmp_path / "external-login.stderr",
        ),
        invocation.command,
        login_session,
    )
    conformance = msgspec.json.decode(
        effective.mcp_servers["conformance"],
        type=CodexEffectiveMcpServer,
    )
    permissions = msgspec.json.decode(
        effective.permissions["conformance_judge"],
        type=CodexPermissionProfile,
    )
    enforced_path = Path("/etc/codex/managed_config.toml")
    enforced = (
        tomllib.loads(enforced_path.read_text()) if enforced_path.exists() else {}
    )
    expected_features = codex_effective_isolated_features() | enforced.get(
        "features", {}
    )
    assert (
        result,
        login_result,
        login_session.response,
        (codex_home / "auth.json").exists(),
        conformance,
        effective.features,
        effective.project_root_markers,
        effective.project_doc_max_bytes,
        effective.default_permissions,
        permissions,
        effective.agents,
        effective.skills,
        CodexModelTransport(
            provider=effective.model_provider,
            openai_base_url=effective.openai_base_url,
            chatgpt_base_url=effective.chatgpt_base_url,
            thread_config_endpoint=effective.experimental_thread_config_endpoint,
        ),
        effective.web_search,
        effective.notify,
        effective.instructions,
        effective.developer_instructions,
        effective.model_instructions_file,
        effective.personality,
        CodexCompactionConfiguration(
            prompt=effective.compact_prompt,
            token_limit=effective.model_auto_compact_token_limit,
            token_limit_scope=effective.model_auto_compact_token_limit_scope,
        ),
        CodexModelRequestConfiguration(
            effective.service_tier,
            effective.model_verbosity,
            effective.model_context_window,
        ),
    ) == (
        ProcessResult(0),
        ProcessResult(0),
        CodexExternalLoginResponse(
            id=2,
            result=CodexExternalLoginResult(),
        ),
        False,
        CodexEffectiveMcpServer(
            command="/nix/conformance-mcp",
            args=(str(evidence),),
            enabled=True,
            required=True,
            default_tools_approval_mode="approve",
        ),
        expected_features,
        (".claude-prompt-conformance-root",),
        0,
        "conformance_judge",
        CodexPermissionProfile(
            filesystem={
                "glob_scan_max_depth": None,
                ":root": "deny",
            },
            network=CodexNetworkPermissions(enabled=False),
        ),
        CodexAgentsConfiguration(enabled=False),
        CodexSkillsConfiguration(
            bundled=CodexBundledSkillsConfiguration(enabled=False),
            include_instructions=False,
        ),
        CodexModelTransport(
            provider="openai",
            openai_base_url="",
            chatgpt_base_url="https://chatgpt.com/backend-api/",
            thread_config_endpoint=None,
        ),
        enforced.get("web_search", "disabled"),
        (),
        "",
        "",
        None,
        enforced.get("personality", "none"),
        CodexCompactionConfiguration("", None, None),
        CodexModelRequestConfiguration("fast", "low", 272000),
    )
