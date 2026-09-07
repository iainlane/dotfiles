from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import overload

import msgspec
import pytest

from claude_prompt_conformance.cli import (
    RUN_FAILURE,
    SETUP_FAILURE,
    FailurePhase,
    ImprovementCalibrationConflictError,
    InterruptEscalation,
    configuration_input,
    main,
    parser,
    report_failure,
    validate_run_mode,
)
from claude_prompt_conformance.protocols.configuration import (
    ClaudeConfigurationInput,
    CodexAgentConfigurationInput,
    CodexConfigurationInput,
    IsolationConfigurationInput,
    PromptVariantConfigurationInput,
    RuntimeConfigurationInput,
)

SUITE_FLAGS = (
    "--fixtures",
    "/nix/store/suite/fixtures.json",
    "--isolation-backend",
    "darwin",
    "--isolation-program",
    "/usr/bin/sandbox-exec",
    "--git-program",
    "/nix/store/git/bin/git",
    "--tls-certificate-bundle",
    "/nix/store/suite/ca-bundle.crt",
    "--claude-program",
    "/nix/store/claude/bin/claude",
    "--claude-shell",
    "/nix/store/bash/bin/bash",
    "--claude-version",
    "1.0.0",
    "--claude-effort",
    "medium",
    "--claude-api-budget",
    "0.75",
    "--claude-oauth-token-url",
    "https://claude.invalid/oauth/token",
    "--claude-oauth-client-id",
    "claude-client",
    "--codex-program",
    "/nix/store/codex/bin/codex",
    "--codex-version",
    "0.146.0",
    "--mcp-program",
    "/nix/store/suite/bin/mcp",
    "--judge-schema",
    "/nix/store/suite/judgement-schema.json",
    "--proposal-schema",
    "/nix/store/suite/proposal-schema.json",
    "--judge-effort",
    "high",
    "--improver-effort",
    "high",
    "--codex-service-tier",
    "fast",
    "--codex-verbosity",
    "low",
    "--codex-context-window",
    "272000",
    "--codex-oauth-token-url",
    "https://codex.invalid/oauth/token",
    "--codex-oauth-client-id",
    "codex-client",
    "--nix-program",
    "/nix/store/nix/bin/nix",
    "--nixpkgs",
    "/nix/store/nixpkgs",
    "--variant-expression",
    "/nix/store/suite/variant.nix",
    "--variant-prompt-environment",
    "/nix/store/suite/prompt-environment.nix",
)

CONFIGURATION_FLAGS = (
    "--managed-settings",
    "/nix/store/prompt/settings.json",
    "--candidate-context",
    "/nix/store/prompt/candidate-context",
    "--workspace-overlay",
    "/nix/store/prompt/workspace-overlay",
    "--prompt-context",
    "/nix/store/prompt/context.json",
    "--prompt-source",
    "/nix/store/prompt/source",
    "--candidate-model",
    "claude-opus-5",
    "--output-style",
    "plain",
    "--judge-model",
    "gpt-5.6-terra",
    "--improver-model",
    "gpt-6-astra",
)

DECLARATION = RuntimeConfigurationInput(
    fixture_manifest="/nix/store/suite/fixtures.json",
    prompt_context="/nix/store/prompt/context.json",
    candidate_context="/nix/store/prompt/candidate-context",
    workspace_overlay="/nix/store/prompt/workspace-overlay",
    git_program="/nix/store/git/bin/git",
    tls_certificate_bundle="/nix/store/suite/ca-bundle.crt",
    claude=ClaudeConfigurationInput(
        program="/nix/store/claude/bin/claude",
        shell="/nix/store/bash/bin/bash",
        version="1.0.0",
        settings="/nix/store/prompt/settings.json",
        model="claude-opus-5",
        effort="medium",
        api_budget_usd="0.75",
        output_style="plain",
        oauth_token_url="https://claude.invalid/oauth/token",
        oauth_client_id="claude-client",
    ),
    codex=CodexConfigurationInput(
        program="/nix/store/codex/bin/codex",
        version="0.146.0",
        mcp_program="/nix/store/suite/bin/mcp",
        judge=CodexAgentConfigurationInput(
            model="gpt-5.6-terra",
            effort="high",
            service_tier="fast",
            verbosity="low",
            context_window=272000,
        ),
        improver=CodexAgentConfigurationInput(
            model="gpt-6-astra",
            effort="high",
            service_tier="fast",
            verbosity="low",
            context_window=272000,
        ),
        schema="/nix/store/suite/judgement-schema.json",
        proposal_schema="/nix/store/suite/proposal-schema.json",
        oauth_token_url="https://codex.invalid/oauth/token",
        oauth_client_id="codex-client",
    ),
    isolation=IsolationConfigurationInput(
        backend="darwin",
        program="/usr/bin/sandbox-exec",
    ),
    variant=PromptVariantConfigurationInput(
        nix_program="/nix/store/nix/bin/nix",
        nixpkgs="/nix/store/nixpkgs",
        expression="/nix/store/suite/variant.nix",
        prompt_environment="/nix/store/suite/prompt-environment.nix",
        prompt_source="/nix/store/prompt/source",
    ),
)


def test_the_flags_of_both_wrappers_describe_the_whole_configuration() -> None:
    arguments = parser().parse_args([*SUITE_FLAGS, *CONFIGURATION_FLAGS, "--list"])

    assert configuration_input(arguments) == DECLARATION


def test_a_repeated_flag_lets_an_operator_replace_a_wrapper_value() -> None:
    arguments = parser().parse_args(
        [*SUITE_FLAGS, *CONFIGURATION_FLAGS, "--judge-model", "gpt-5.6-luna", "--list"]
    )

    assert configuration_input(arguments) == msgspec.structs.replace(
        DECLARATION,
        codex=msgspec.structs.replace(
            DECLARATION.codex,
            judge=msgspec.structs.replace(
                DECLARATION.codex.judge, model="gpt-5.6-luna"
            ),
        ),
    )


class InterruptingArguments(Sequence[str]):
    @overload
    def __getitem__(self, index: int) -> str: ...
    @overload
    def __getitem__(self, index: slice) -> Sequence[str]: ...
    def __getitem__(self, index: int | slice) -> str | Sequence[str]:
        raise KeyboardInterrupt

    def __len__(self) -> int:
        return 1


def test_cli_returns_the_conventional_status_for_sigint() -> None:
    assert main(InterruptingArguments()) == 130


@dataclass
class AnnouncementRecorder:
    messages: list[str] = field(default_factory=list)

    def announce(self, message: str) -> None:
        self.messages.append(message)


@dataclass
class ForcedExit(Exception):
    status: int


def test_a_second_interrupt_kills_agents_and_exits_immediately() -> None:
    frontend = AnnouncementRecorder()
    killed: list[bool] = []

    def exit_now(status: int) -> None:
        raise ForcedExit(status)

    handler = InterruptEscalation(
        frontend,
        kill=lambda: killed.append(True),
        exit_now=exit_now,
    )

    with pytest.raises(KeyboardInterrupt):
        handler(2, None)
    with pytest.raises(ForcedExit) as forced:
        handler(2, None)

    banner = (
        "Interrupt received: stopping agents. Press Ctrl-C again to exit immediately."
    )
    assert (frontend.messages, killed, forced.value) == (
        [banner],
        [True],
        ForcedExit(130),
    )


def test_prompt_improvement_requires_calibrated_evidence() -> None:
    with pytest.raises(ImprovementCalibrationConflictError) as raised:
        validate_run_mode(improve=True, skip_calibration=True)

    assert raised.value == ImprovementCalibrationConflictError()


@pytest.mark.parametrize(
    ("phase", "event", "status"),
    [
        (SETUP_FAILURE, "SetupFailed", 2),
        (RUN_FAILURE, "RunFailed", 3),
    ],
)
def test_a_json_failure_names_its_phase_and_error(
    phase: FailurePhase,
    event: str,
    status: int,
    capsys,
) -> None:
    error = ImprovementCalibrationConflictError()

    assert report_failure(phase, error, "json") == status
    assert capsys.readouterr().out == (
        f'{{"event": "{event}", "error": '
        '{"type": "ImprovementCalibrationConflictError", '
        '"description": "--skip-calibration cannot be used during prompt improvement"}}\n'
    )
