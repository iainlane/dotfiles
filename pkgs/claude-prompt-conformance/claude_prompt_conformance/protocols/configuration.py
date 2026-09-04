"""Schemas for Nix-assembled suite and fixture configuration."""

from typing import Literal

import msgspec


class RepositoryInput(msgspec.Struct, frozen=True):
    url: str
    revision: str


class CriterionInput(msgspec.Struct, frozen=True):
    identifier: str = msgspec.field(name="id")
    kind: str
    requirement: str
    calibrate: bool = True


class VerificationInput(msgspec.Struct, frozen=True, rename="camel"):
    name: str
    command: tuple[str, ...]
    kind: str = "gate"
    expected_return_code: int = 0
    working_directory: str = "."


class PreparationInput(msgspec.Struct, frozen=True, rename="camel"):
    name: str
    command: tuple[str, ...]
    working_directory: str = "."


class CalibrationInput(msgspec.Struct, frozen=True, rename="camel"):
    name: str
    repository: RepositoryInput
    response: str
    expected_criteria: dict[str, bool]


class FixtureInput(msgspec.Struct, frozen=True, rename="camel"):
    name: str
    description: str
    kind: str
    use: str
    category: str
    tags: tuple[str, ...]
    path: str
    task: str
    repository: RepositoryInput
    comparison_revision: str
    environment_path: str
    criteria: tuple[CriterionInput, ...]
    verification: tuple[VerificationInput, ...]
    calibration: tuple[CalibrationInput, ...]
    preparation: tuple[PreparationInput, ...] = ()


class ClaudeConfigurationInput(msgspec.Struct, frozen=True, rename="camel"):
    program: str
    shell: str
    settings: str
    model: str
    effort: str
    api_budget_usd: str
    output_style: str
    oauth_token_url: str
    oauth_client_id: str


class CodexAgentConfigurationInput(msgspec.Struct, frozen=True, rename="camel"):
    model: str
    effort: str
    service_tier: str
    verbosity: Literal["low", "medium", "high"]
    context_window: int


class CodexConfigurationInput(msgspec.Struct, frozen=True, rename="camel"):
    program: str
    mcp_program: str
    judge: CodexAgentConfigurationInput
    improver: CodexAgentConfigurationInput
    schema: str
    proposal_schema: str
    tls_certificate_bundle: str
    oauth_token_url: str
    oauth_client_id: str


class IsolationConfigurationInput(msgspec.Struct, frozen=True):
    backend: str
    program: str | None


class PromptVariantConfigurationInput(msgspec.Struct, frozen=True, rename="camel"):
    nix_program: str
    nixpkgs: str
    expression: str
    prompt_environment: str
    prompt_source: str


class RuntimeConfigurationInput(msgspec.Struct, frozen=True, rename="camel"):
    fixture_manifest: str
    run_metadata: str
    prompt_context: str
    candidate_context: str
    workspace_overlay: str
    git_program: str
    claude: ClaudeConfigurationInput
    codex: CodexConfigurationInput
    isolation: IsolationConfigurationInput
    variant: PromptVariantConfigurationInput
