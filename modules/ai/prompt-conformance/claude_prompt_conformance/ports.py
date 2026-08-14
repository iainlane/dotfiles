"""Capability interfaces used by the conformance orchestration layer."""

from collections.abc import Callable
from contextlib import AbstractContextManager
from pathlib import Path
from types import TracebackType
from typing import Protocol

from .credentials import ClaudeCredential
from .models import (
    CalibrationAssessment,
    CandidateResult,
    ClaudeBillingMode,
    Event,
    Fixture,
    FixtureCheckpoint,
    InstancePaths,
    Judgement,
    JudgementSubject,
    KeychainItem,
    KeychainRevision,
    ProcessExchange,
    ProcessInvocation,
    ProcessOutputRecord,
    ProcessResult,
    PromptProposal,
    RepositorySpec,
    RetainedCalibration,
    RuntimeConfiguration,
    SecretFileDescriptor,
    TestResult,
    VerificationResult,
    WorkspaceEvidence,
)
from .protocols.claude import ClaudeOAuth
from .protocols.codex_auth import CodexAccessCredential


class EventSink(Protocol):
    """Receive lifecycle events for presentation or structured output."""

    def emit(self, event: Event) -> None: ...


class ProcessRunner(Protocol):
    """Run a process with an explicit filesystem and network capability set."""

    def run(self, invocation: ProcessInvocation) -> ProcessResult: ...


class InteractiveProcessRunner(ProcessRunner, Protocol):
    """Run processes which exchange records over retained standard input."""

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: "ProcessSession",
    ) -> ProcessResult: ...


class ProcessSession(Protocol):
    """Drive a line-oriented bidirectional child-process protocol."""

    def initial_input(self) -> tuple[bytes, ...]: ...

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange: ...


class ProcessController(Protocol):
    """Stop every process owned by the current suite run."""

    def cancel(self) -> None: ...


class IsolatedChildProcesses(Protocol):
    """Execute the isolated command an isolation backend has assembled."""

    def run(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
    ) -> ProcessResult: ...

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
        session: "ProcessSession",
    ) -> ProcessResult: ...


class AgentSlots(Protocol):
    """Bound the number of concurrently active model-agent processes."""

    def hold(self) -> AbstractContextManager[None]: ...


class CancellationSignal(Protocol):
    """Broadcast and observe run cancellation without a concrete event type."""

    def set(self) -> None: ...

    def is_set(self) -> bool: ...


class ActivityReporter(Protocol):
    """Report observable work without coupling it to a presentation frontend."""

    def start_activity(self, identifier: str, description: str) -> None: ...

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None: ...

    def finish_activity(self, identifier: str, detail: str) -> None: ...


class InstanceFactory(Protocol):
    """Allocate and retire the private directories for one agent instance."""

    def create(self, name: str, results: Path) -> InstancePaths: ...

    def clean(self, instance: InstancePaths) -> None: ...


class RepositoryMaterialiser(Protocol):
    """Materialise an exact repository revision with isolated Git state."""

    def materialise(
        self,
        repository: RepositorySpec,
        destination: Path,
        control: Path,
        environment_path: str,
        comparison_revision: str,
    ) -> None: ...


class WorkspaceOverlay(Protocol):
    """Install the controlled prompt files into a prepared workspace."""

    def install(self, workspace: Path) -> None: ...


class WorkspacePreparer(Protocol):
    """Install fixture dependencies inside a materialised workspace."""

    def prepare(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> None: ...


class CandidateAgent(Protocol):
    """Perform the fixture task and return its response and action evidence."""

    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult: ...


class ProcessIdentity(Protocol):
    """Prepare instance-scoped authentication for a model client process."""

    def environment(self, state: Path) -> dict[str, str]: ...

    def secrets(self) -> tuple[SecretFileDescriptor, ...]: ...


class ClaudeIdentity(Protocol):
    """Provide Claude authentication and identify its billing mechanism."""

    @property
    def billing_mode(self) -> ClaudeBillingMode: ...

    def environment(self, state: Path) -> dict[str, str]: ...

    def access_token(self) -> str: ...

    def refresh_access_token(self, rejected: str, deadline: float) -> str: ...


class CodexAuthentication(Protocol):
    """Supply and refresh external authentication for Codex app-server."""

    def authentication(self) -> CodexAccessCredential: ...

    def refresh(
        self,
        rejected_access_token: str,
        expected_account_id: str | None,
    ) -> CodexAccessCredential: ...


class CodexIdentity(ProcessIdentity, CodexAuthentication, Protocol):
    """Prepare isolated Codex processes backed by run-scoped authentication."""


class Keychain(Protocol):
    """Read and update a generic password in platform credential storage."""

    def generic_password(self, account: str, service: str) -> KeychainItem: ...

    def generic_password_revision(
        self,
        persistent_reference: bytes,
    ) -> KeychainRevision: ...

    def update_generic_password(
        self,
        persistent_reference: bytes,
        value: bytes,
    ) -> None: ...


class ClaudeCredentialStore(Protocol):
    """Load and persist the ordinary Claude login credential."""

    def load(self) -> ClaudeCredential: ...

    def mutate(
        self,
        transform: Callable[[ClaudeCredential], ClaudeCredential],
    ) -> ClaudeCredential: ...


class ReconcilableCredentials(Protocol):
    """Read and durably replace the credential one backend keeps for Claude."""

    def current(self) -> ClaudeCredential: ...

    def replace(self, credential: ClaudeCredential) -> ClaudeCredential: ...


class CredentialLock(Protocol):
    """Hold one Claude-compatible cross-process credential lock."""

    def __enter__(self) -> None: ...

    def check(self) -> None: ...

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None: ...


class ClaudeCredentialRefresher(Protocol):
    """Exchange a renewable Claude credential for current OAuth tokens."""

    def refresh(self, credential: ClaudeOAuth, deadline: float) -> ClaudeOAuth: ...


class WorkspaceInspector(Protocol):
    """Capture a stable description of the work produced in a repository."""

    def inspect(
        self,
        workspace: Path,
        base_revision: str,
        artefacts: Path,
        environment_path: str,
    ) -> WorkspaceEvidence: ...


class Verifier(Protocol):
    """Run deterministic fixture checks and retain their complete results."""

    def verify(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> tuple[VerificationResult, ...]: ...


class Judge(Protocol):
    """Assess one blind subject against the fixture's declared criteria."""

    def assess(
        self,
        fixture: Fixture,
        subject: JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> Judgement: ...


class FixtureResultStore(Protocol):
    """Persist and recover complete phase outcomes for automatic resumption."""

    def load(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        *,
        calibrate: bool,
    ) -> FixtureCheckpoint | TestResult | None: ...

    def load_calibration(
        self,
        root: Path,
        fixture: Fixture,
        *,
        judge: str,
    ) -> RetainedCalibration | None: ...

    def reset(
        self,
        root: Path,
        artefacts: Path,
        *,
        retain_calibration: bool = False,
    ) -> None: ...

    def save_calibration(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        calibration: tuple[CalibrationAssessment, ...],
        *,
        judge: str,
    ) -> None: ...

    def save_checkpoint(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        checkpoint: FixtureCheckpoint,
    ) -> None: ...

    def save_result(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        result: TestResult,
    ) -> None: ...


class PromptImprover(Protocol):
    """Propose one general prompt change from aggregated evaluation evidence."""

    def propose(
        self,
        configuration: RuntimeConfiguration,
        evidence: Path,
        environment_path: str,
        instance: InstancePaths,
        artefacts: Path,
        angle: str,
    ) -> PromptProposal: ...


class PromptVariantBuilder(Protocol):
    """Construct an immutable prompt configuration from one proposal."""

    def build(
        self,
        configuration: RuntimeConfiguration,
        proposal: PromptProposal,
        artefacts: Path,
        root: Path,
    ) -> RuntimeConfiguration: ...
