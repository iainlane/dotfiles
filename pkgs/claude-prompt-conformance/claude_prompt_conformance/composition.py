"""Production composition of domain capabilities and host adapters."""

import os
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType
from typing import Self

from .backend import ConformanceSuite
from .checkpoints import JsonFixtureResultStore
from .claude_storage import ClaudeSecureStorage
from .clients import ClaudeCandidateAgent, CodexJudge, CodexPromptImprover
from .codex_identity import CodexHostIdentity, RunCancellation
from .credential_lock import (
    ClaudeCredentialRefreshLock,
    ClaudeCredentialStorageLock,
)
from .errors import ConformanceError
from .identities import (
    AnthropicOAuthRefresher,
    ClaudeFileCredentialStore,
    ClaudeOAuthIdentity,
)
from .models import CodexHostConfiguration, RuntimeConfiguration
from .platforms import (
    DarwinClaudeCredentialStore,
    DarwinProcessRunner,
    LinuxProcessRunner,
    PyObjCKeychain,
    claude_keychain_namespace,
    load_codex_host_configuration,
)
from .ports import (
    AgentSlots,
    ClaudeCredentialStore,
    ClaudeIdentity,
    EventSink,
    InstanceFactory,
    InteractiveProcessRunner,
    ProcessController,
    PromptImprover,
    PromptVariantBuilder,
)
from .process import ProcessSupervisor
from .progress import TaskScopes
from .variants import NixPromptVariantBuilder
from .verification import CommandVerifier, CommandWorkspacePreparer
from .workspace import (
    DirectoryInstanceFactory,
    GitRepositoryMaterialiser,
    GitWorkspaceInspector,
    LinkedWorkspaceOverlay,
)


@dataclass(eq=True)
class IsolationProgramMissingError(ConformanceError):
    backend: str

    def __str__(self) -> str:
        return f"isolation backend {self.backend!r} has no program"


@dataclass(eq=True)
class IsolationBackendUnknownError(ConformanceError):
    backend: str

    def __str__(self) -> str:
        return f"unknown isolation backend {self.backend!r}"


@dataclass(frozen=True)
class Application:
    suite: ConformanceSuite
    improver: PromptImprover
    variants: PromptVariantBuilder
    instances: InstanceFactory
    processes: ProcessController


@dataclass(frozen=True)
class RunAuthentication:
    """Authentication and host configuration retained for one complete run."""

    claude: ClaudeIdentity
    codex: CodexHostIdentity
    codex_configuration: CodexHostConfiguration
    cancellation: RunCancellation

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.codex.finish()


@dataclass(frozen=True)
class ApplicationFactory:
    """Construct variant-specific applications from run-scoped capabilities."""

    tasks: TaskScopes
    authentication: RunAuthentication
    slots: AgentSlots

    def __call__(
        self,
        configuration: RuntimeConfiguration,
        events: EventSink,
    ) -> Application:
        """Construct one application without reacquiring host authentication."""

        processes = ProcessSupervisor(self.authentication.cancellation)
        runner = process_runner(configuration, processes)
        instances = DirectoryInstanceFactory()
        return Application(
            suite=ConformanceSuite(
                instances=instances,
                repositories=GitRepositoryMaterialiser(
                    runner, configuration.git_program
                ),
                overlay=LinkedWorkspaceOverlay(configuration.workspace_overlay),
                preparer=CommandWorkspacePreparer(runner),
                candidate=ClaudeCandidateAgent(
                    configuration, runner, self.authentication.claude
                ),
                inspector=GitWorkspaceInspector(runner, configuration.git_program),
                verifier=CommandVerifier(runner),
                judge=CodexJudge(
                    configuration,
                    runner,
                    self.authentication.codex,
                    self.authentication.codex_configuration,
                ),
                events=events,
                tasks=self.tasks,
                processes=processes,
                slots=self.slots,
                results=JsonFixtureResultStore(),
                run_metadata=configuration.run_metadata,
                prompt_context=configuration.prompt_context,
            ),
            improver=CodexPromptImprover(
                configuration,
                runner,
                self.authentication.codex,
                self.authentication.codex_configuration,
            ),
            variants=NixPromptVariantBuilder(runner),
            instances=instances,
            processes=processes,
        )


def acquire_run_authentication(
    configuration: RuntimeConfiguration,
    claude_credentials: ClaudeCredentialStore | None = None,
) -> RunAuthentication:
    """Acquire authentication which remains valid for the complete run."""

    codex_configuration = load_codex_host_configuration()
    credentials = claude_credentials or platform_claude_credentials(configuration)
    cancellation = RunCancellation()
    return RunAuthentication(
        claude=ClaudeOAuthIdentity(
            credentials.load(),
            credentials,
            AnthropicOAuthRefresher(
                configuration.claude.oauth_token_url,
                configuration.claude.oauth_client_id,
            ),
        ),
        codex=CodexHostIdentity.from_environment(
            os.environ,
            Path.home(),
            configuration.codex.oauth_token_url,
            configuration.codex.oauth_client_id,
            cancellation,
        ),
        codex_configuration=codex_configuration,
        cancellation=cancellation,
    )


def process_runner(
    configuration: RuntimeConfiguration, processes: ProcessSupervisor
) -> InteractiveProcessRunner:
    isolation = configuration.isolation
    if isolation.program is None:
        raise IsolationProgramMissingError(isolation.backend)
    if isolation.backend == "darwin":
        return DarwinProcessRunner(isolation.program, processes)
    if isolation.backend == "linux":
        return LinuxProcessRunner(isolation.program, processes)
    raise IsolationBackendUnknownError(isolation.backend)


def platform_claude_credentials(
    configuration: RuntimeConfiguration,
) -> ClaudeCredentialStore:
    """Select the host credential source for the configured platform."""

    storage = ClaudeSecureStorage.from_environment(os.environ, Path.home())
    configuration_directory = storage.directory
    lock = ClaudeCredentialRefreshLock(configuration_directory)
    storage_lock = ClaudeCredentialStorageLock(configuration_directory)
    isolation = configuration.isolation
    if isolation.backend == "darwin":
        namespace = claude_keychain_namespace(
            os.environ,
            storage,
        )
        credentials = DarwinClaudeCredentialStore(
            namespace.account,
            namespace.service,
            PyObjCKeychain(),
            lock,
            storage_lock,
        )
        return credentials
    return ClaudeFileCredentialStore(
        configuration_directory / ".credentials.json",
        lock,
        storage_lock,
    )
