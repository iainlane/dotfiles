"""Drive the packaged Claude client against a scripted Messages endpoint.

The stream schema in `protocols.claude` is this suite's own contract for the
pinned client; upstream publishes no schema for the stream. This test exists
so a client upgrade whose records no longer fit that contract fails a check
instead of a billed run.
"""

import json
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from claude_prompt_conformance.agents.candidate import ClaudeCandidateAgent
from claude_prompt_conformance.claude_session import decode_stream_record
from claude_prompt_conformance.models import (
    ClaudeBillingMode,
    ClaudeConfiguration,
    CodexAgentConfiguration,
    CodexConfiguration,
    InstancePaths,
    IsolationConfiguration,
    PromptVariantConfiguration,
    RuntimeConfiguration,
)
from claude_prompt_conformance.platforms.direct import DirectProcessRunner
from claude_prompt_conformance.process import ProcessSupervisor
from claude_prompt_conformance.protocols.claude import (
    ClaudeAssistantRecord,
    ClaudeResultRecord,
    ClaudeSystemRecord,
    ClaudeUserRecord,
)

from .claude_stream_protocol import ScriptedMessagesEndpoint, text, tool_use
from .helpers import make_fixture

OUTPUT_STYLE = "Plain technical prose"
MODEL = "claude-opus-5"
FINAL_RESPONSE = "The requested deletion was refused; nothing was changed."


def required_program(name: str) -> str:
    """Locate one packaged program the endpoint tests drive for real."""

    program = shutil.which(name)
    if program is None:
        pytest.fail(f"the pinned {name} executable is required for endpoint tests")
    return program


@dataclass
class ScriptedClaudeIdentity:
    """Bill against a scripted endpoint instead of a real Anthropic account."""

    base_url: str

    @property
    def billing_mode(self) -> ClaudeBillingMode:
        return ClaudeBillingMode.API

    def environment(self, state: Path) -> dict[str, str]:
        return {
            "ANTHROPIC_API_KEY": "conformance-endpoint-key",
            "ANTHROPIC_BASE_URL": self.base_url,
            "HOME": str(state),
        }

    def access_token(self) -> str:
        return "conformance-endpoint-key"

    def refresh_access_token(self, rejected: str, deadline: float) -> str:
        raise AssertionError("the endpoint test never refreshes credentials")


@dataclass
class RecordingActivity:
    events: list[tuple[str, str]] = field(default_factory=list)

    def start_activity(self, identifier: str, description: str) -> None:
        self.events.append(("started", identifier))

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None:
        self.events.append(("heartbeat", identifier))

    def finish_activity(self, identifier: str, detail: str) -> None:
        self.events.append(("finished", identifier))


def build_configuration(root: Path, claude: str) -> RuntimeConfiguration:
    """Assemble the runtime configuration a Claude candidate needs, without Nix."""

    root.mkdir(parents=True)
    settings = root / "settings.json"
    settings.write_text(json.dumps({"outputStyle": OUTPUT_STYLE}))
    context = root / "candidate-context"
    (context / "rules").mkdir(parents=True)
    (context / "rules" / "AGENTS.md").write_text("Be precise.\n")
    styles = context / "output-styles"
    styles.mkdir()
    (styles / "plain-technical-prose.md").write_text(
        f"---\nname: {OUTPUT_STYLE}\ndescription: Test style.\n---\nWrite plainly.\n"
    )
    agent = CodexAgentConfiguration("gpt-5.6-terra", "high", "fast", "low", 272000)
    return RuntimeConfiguration(
        fixture_manifest=root / "fixtures.json",
        run_metadata=root / "run.json",
        prompt_context=context,
        candidate_context=context,
        workspace_overlay=root / "overlay",
        git_program="git",
        claude=ClaudeConfiguration(
            program=claude,
            shell=os.environ.get("SHELL", "/bin/sh"),
            settings=settings,
            model=MODEL,
            effort="medium",
            api_budget_usd="0.75",
            output_style=OUTPUT_STYLE,
            oauth_token_url="https://claude.invalid/oauth/token",
            oauth_client_id="claude-client",
        ),
        codex=CodexConfiguration(
            program="codex",
            mcp_program="claude-prompt-conformance-mcp",
            judge=agent,
            improver=agent,
            schema=root / "judgement.json",
            proposal_schema=root / "proposal.json",
            tls_certificate_bundle=root / "ca-bundle.crt",
            oauth_token_url="https://codex.invalid/oauth/token",
            oauth_client_id="codex-client",
        ),
        isolation=IsolationConfiguration("direct", None),
        variant=PromptVariantConfiguration(
            nix_program="nix",
            nixpkgs=root,
            expression=root / "variant.nix",
            prompt_environment=root / "prompt-environment.nix",
            prompt_source=root / "prompt-source",
        ),
        source=root / "configuration.json",
    )


def build_instance(root: Path) -> InstancePaths:
    instance = InstancePaths(
        root=root,
        workspace=root / "workspace",
        control=root / "control",
        candidate_state=root / "candidate-state",
        candidate_cache=root / "candidate-cache",
        candidate_temp=root / "candidate-temp",
        judge_state=root / "judge-state",
        judge_cache=root / "judge-cache",
        judge_temp=root / "judge-temp",
    )
    for path in instance.__dict__.values():
        path.mkdir(parents=True, exist_ok=True)
    return instance


@pytest.mark.endpoint_integration
@pytest.mark.timeout(180)
def test_claude_candidate_speaks_the_stream_contract(tmp_path: Path) -> None:
    """Every record of a real turn, including a tool denial, must decode."""

    claude = required_program("claude")
    configuration = build_configuration(tmp_path / "runtime", claude)
    fixture = make_fixture(tmp_path / "fixtures", environment_path=os.environ["PATH"])
    instance = build_instance(tmp_path / "instance")
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    activity = RecordingActivity()

    denied_command = 'rm -rf "$CONFORMANCE_SCRATCH"/*'
    replies = (
        (
            tool_use(
                "toolu-denied",
                "Bash",
                {"command": denied_command, "description": "Clear the scratch"},
            ),
        ),
        (text(FINAL_RESPONSE),),
    )
    with ScriptedMessagesEndpoint(replies) as endpoint:
        result = ClaudeCandidateAgent(
            configuration,
            DirectProcessRunner(ProcessSupervisor()),
            ScriptedClaudeIdentity(endpoint.base_url),
        ).run(fixture, instance, artefacts, activity)
        requested = endpoint.requests
        unexpected = endpoint.unexpected_paths

    records = tuple(
        decode_stream_record(line.encode())
        for line in (artefacts / "claude-events.jsonl").read_text().splitlines()
    )
    denials = tuple(
        record
        for record in records
        if isinstance(record, ClaudeSystemRecord)
        and record.subtype == "permission_denied"
    )
    tool_errors = requested[-1].tool_results() if requested else ()
    assert (
        result.response,
        unexpected,
        len(requested),
        [request.model for request in requested],
        "Bash" in requested[0].tool_names if requested else None,
        len(denials),
        [type(record.message) for record in denials],
        any(isinstance(record, ClaudeAssistantRecord) for record in records),
        any(isinstance(record, ClaudeUserRecord) for record in records),
        any(isinstance(record, ClaudeResultRecord) for record in records),
        [bool(block.get("is_error")) for block in tool_errors],
    ) == (
        FINAL_RESPONSE,
        (),
        2,
        [MODEL, MODEL],
        True,
        1,
        [str],
        True,
        True,
        True,
        [True],
    )
