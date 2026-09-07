"""Typed domain values shared by the conformance suite's capabilities."""

from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Literal

import msgspec

from .errors import ConformanceError
from .protocols.codex import JudgementResponse, PromptProposalResponse
from .protocols.configuration import FixtureInput, RuntimeConfigurationInput
from .storage import RUN_METADATA_DOCUMENT


@dataclass(eq=True)
class RuntimeConfigurationFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"runtime configuration {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class JudgementFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"the judge output at {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class JudgementCriteriaError(ConformanceError):
    expected: tuple[str, ...]
    actual: tuple[str, ...]

    def __str__(self) -> str:
        return "the judge did not assess every criterion exactly once"


@dataclass(eq=True)
class JudgementCriteriaEmptyError(ConformanceError):
    def __str__(self) -> str:
        return "the judgement assessed no criteria"


@dataclass(eq=True)
class JudgementEvidenceMissingError(ConformanceError):
    criterion: str

    def __str__(self) -> str:
        return f"the judge supplied no evidence for criterion {self.criterion!r}"


@dataclass(eq=True)
class PassingJudgementInconsistentError(ConformanceError):
    def __str__(self) -> str:
        return "the passing judgement contains failure-only fields"


@dataclass(eq=True)
class FailingJudgementIncompleteError(ConformanceError):
    def __str__(self) -> str:
        return "the failing judgement omits its cause or corrective work"


@dataclass(eq=True)
class PromptProposalFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"the prompt proposal at {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class NoChangeProposalHasPatchError(ConformanceError):
    def __str__(self) -> str:
        return "a no-change prompt proposal cannot contain a patch"


@dataclass(eq=True)
class PromptProposalMissingPatchError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal must contain a patch"


@dataclass(eq=True)
class PromptProposalTitleMissingError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal must have a progress title"


@dataclass(eq=True)
class PromptProposalTitleFormatError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal progress title must be one trimmed line"


@dataclass(eq=True)
class PromptProposalObservationsMissingError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal must identify the evidence it explains"


@dataclass(eq=True)
class PromptProposalChangeMissingError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal must describe its intended change"


@dataclass(eq=True)
class PromptProposalReasoningMissingError(ConformanceError):
    def __str__(self) -> str:
        return "a prompt proposal must explain why its change should help"


class TaskKind(StrEnum):
    """The kind of repository interaction requested by a fixture."""

    AUTHOR = "author"
    RESPOND = "respond"
    REVISE = "revise"
    REVIEW = "review"


class CriterionKind(StrEnum):
    """The source of evidence that establishes a criterion."""

    OUTCOME = "outcome"
    PROCESS = "process"
    COMMUNICATION = "communication"


class ClaudeBillingMode(StrEnum):
    """The account against which a Claude invocation consumes usage."""

    SUBSCRIPTION = "subscription"
    API = "api"


@dataclass(frozen=True)
class KeychainRevision:
    """The modification timestamp used to detect an external Keychain update."""

    timestamp: float


@dataclass(frozen=True)
class KeychainItem:
    """A Keychain secret and the identity and revision observed with it."""

    value: bytes
    revision: KeychainRevision
    persistent_reference: bytes


@dataclass(frozen=True)
class ClaudeKeychainNamespace:
    """The account and service used by Claude's secure credential backend."""

    account: str
    service: str


class FixtureUse(StrEnum):
    """How a fixture contributes evidence to prompt improvement."""

    WORKING = "working"
    RESERVED = "reserved"


class VerificationKind(StrEnum):
    """Whether a deterministic check decides the candidate result."""

    GATE = "gate"
    DIAGNOSTIC = "diagnostic"


class FailureOrigin(StrEnum):
    """The system component most likely responsible for a failed result."""

    NONE = "none"
    CANDIDATE = "candidate"
    PROMPT = "prompt"
    FIXTURE = "fixture"
    ENVIRONMENT = "environment"
    JUDGE = "judge"
    UNCERTAIN = "uncertain"


class TestStatus(StrEnum):
    """The terminal status of one fixture run."""

    PASSED = "passed"
    FAILED = "failed"
    INVALID = "invalid"
    STALE = "stale"
    INTERRUPTED = "interrupted"


@dataclass(frozen=True)
class RepositorySpec:
    url: str
    revision: str


@dataclass(frozen=True)
class Criterion:
    identifier: str
    kind: CriterionKind
    requirement: str
    calibrate: bool


@dataclass(frozen=True)
class VerificationCommand:
    name: str
    command: tuple[str, ...]
    kind: VerificationKind
    expected_return_code: int
    working_directory: str


@dataclass(frozen=True)
class PreparationCommand:
    name: str
    command: tuple[str, ...]
    working_directory: str


@dataclass(frozen=True)
class CalibrationCandidate:
    name: str
    repository: RepositorySpec
    response: Path
    expected_criteria: tuple[tuple[str, bool], ...]


@dataclass(frozen=True)
class Fixture:
    """A repository task, its evidence requirements, and judge calibration."""

    name: str
    description: str
    kind: TaskKind
    use: FixtureUse
    category: str
    tags: tuple[str, ...]
    path: Path
    task: Path
    repository: RepositorySpec
    comparison_revision: str
    environment_path: str
    criteria: tuple[Criterion, ...]
    verification: tuple[VerificationCommand, ...]
    calibration: tuple[CalibrationCandidate, ...]
    preparation: tuple[PreparationCommand, ...] = ()

    @classmethod
    def from_input(cls, value: FixtureInput) -> "Fixture":
        """Construct the domain fixture after typed JSON decoding."""

        return cls(
            name=value.name,
            description=value.description,
            kind=TaskKind(value.kind),
            use=FixtureUse(value.use),
            category=value.category,
            tags=value.tags,
            path=Path(value.path),
            task=Path(value.task),
            repository=RepositorySpec(value.repository.url, value.repository.revision),
            comparison_revision=value.comparison_revision,
            environment_path=value.environment_path,
            criteria=tuple(
                Criterion(
                    criterion.identifier,
                    CriterionKind(criterion.kind),
                    criterion.requirement,
                    criterion.calibrate,
                )
                for criterion in value.criteria
            ),
            verification=tuple(
                VerificationCommand(
                    check.name,
                    check.command,
                    VerificationKind(check.kind),
                    check.expected_return_code,
                    check.working_directory,
                )
                for check in value.verification
            ),
            calibration=tuple(
                CalibrationCandidate(
                    candidate.name,
                    RepositorySpec(
                        candidate.repository.url,
                        candidate.repository.revision,
                    ),
                    Path(candidate.response),
                    tuple(sorted(candidate.expected_criteria.items())),
                )
                for candidate in value.calibration
            ),
            preparation=tuple(
                PreparationCommand(
                    command.name,
                    command.command,
                    command.working_directory,
                )
                for command in value.preparation
            ),
        )


@dataclass(frozen=True)
class ClaudeConfiguration:
    program: str
    shell: str
    settings: Path
    model: str
    effort: str
    api_budget_usd: str
    output_style: str
    oauth_token_url: str
    oauth_client_id: str


@dataclass(frozen=True)
class CodexAgentConfiguration:
    model: str
    effort: str
    service_tier: str
    verbosity: Literal["low", "medium", "high"]
    context_window: int


@dataclass(frozen=True)
class CodexConfiguration:
    program: str
    mcp_program: str
    judge: CodexAgentConfiguration
    improver: CodexAgentConfiguration
    schema: Path
    proposal_schema: Path
    oauth_token_url: str
    oauth_client_id: str


@dataclass(frozen=True)
class PromptVariantConfiguration:
    """Nix inputs used to construct one immutable prompt variant."""

    nix_program: str
    nixpkgs: Path
    expression: Path
    prompt_environment: Path
    prompt_source: Path


class IsolationBackend(StrEnum):
    """The sandbox that confines the child processes of a run."""

    DARWIN = "darwin"
    LINUX = "linux"


@dataclass(frozen=True)
class IsolationConfiguration:
    backend: IsolationBackend
    program: str | None


@dataclass(frozen=True)
class RuntimeConfiguration:
    """The programs, prompt artefacts, fixtures and isolation policy of one run."""

    fixture_manifest: Path
    run_metadata: Path
    prompt_context: Path
    candidate_context: Path
    workspace_overlay: Path
    git_program: str
    tls_certificate_bundle: Path
    claude: ClaudeConfiguration
    codex: CodexConfiguration
    isolation: IsolationConfiguration
    variant: PromptVariantConfiguration
    source: Path

    @classmethod
    def from_file(cls, path: Path) -> "RuntimeConfiguration":
        try:
            value = msgspec.json.decode(
                path.read_bytes(), type=RuntimeConfigurationInput
            )
        except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
            raise RuntimeConfigurationFormatError(path, error) from error
        return cls.from_input(path, value)

    @classmethod
    def from_input(
        cls,
        path: Path,
        value: RuntimeConfigurationInput,
    ) -> "RuntimeConfiguration":
        """Construct a runtime configuration from an already decoded document.

        The suite computes the run metadata from the same values, and writes it
        beside the configuration document, so `path` locates both.
        """

        try:
            return cls(
                fixture_manifest=Path(value.fixture_manifest),
                run_metadata=path.with_name(RUN_METADATA_DOCUMENT),
                prompt_context=Path(value.prompt_context),
                candidate_context=Path(value.candidate_context),
                workspace_overlay=Path(value.workspace_overlay),
                git_program=value.git_program,
                tls_certificate_bundle=Path(value.tls_certificate_bundle),
                claude=ClaudeConfiguration(
                    value.claude.program,
                    value.claude.shell,
                    Path(value.claude.settings),
                    value.claude.model,
                    value.claude.effort,
                    value.claude.api_budget_usd,
                    value.claude.output_style,
                    value.claude.oauth_token_url,
                    value.claude.oauth_client_id,
                ),
                codex=CodexConfiguration(
                    value.codex.program,
                    value.codex.mcp_program,
                    CodexAgentConfiguration(
                        value.codex.judge.model,
                        value.codex.judge.effort,
                        value.codex.judge.service_tier,
                        value.codex.judge.verbosity,
                        value.codex.judge.context_window,
                    ),
                    CodexAgentConfiguration(
                        value.codex.improver.model,
                        value.codex.improver.effort,
                        value.codex.improver.service_tier,
                        value.codex.improver.verbosity,
                        value.codex.improver.context_window,
                    ),
                    Path(value.codex.schema),
                    Path(value.codex.proposal_schema),
                    value.codex.oauth_token_url,
                    value.codex.oauth_client_id,
                ),
                isolation=IsolationConfiguration(
                    IsolationBackend(value.isolation.backend),
                    value.isolation.program,
                ),
                variant=PromptVariantConfiguration(
                    value.variant.nix_program,
                    Path(value.variant.nixpkgs),
                    Path(value.variant.expression),
                    Path(value.variant.prompt_environment),
                    Path(value.variant.prompt_source),
                ),
                source=path,
            )
        except ValueError as error:
            raise RuntimeConfigurationFormatError(path, error) from error


@dataclass(frozen=True)
class PromptProposal:
    """One bounded prompt change proposed from aggregated evaluation evidence."""

    no_change: bool
    title: str
    observations: tuple[str, ...]
    change: str
    reasoning: str
    risks: tuple[str, ...]
    patch: str

    def __post_init__(self) -> None:
        self.validate()

    def validate(self) -> None:
        """Reject an incomplete proposal, or a patch that contradicts `no_change`.

        A title, observations and reasoning are always required, and a change
        description whenever the proposal is not `no_change`. A `no_change`
        proposal must have no patch, and every other proposal must have one.
        """

        if self.no_change and self.patch:
            raise NoChangeProposalHasPatchError
        if not self.no_change and not self.patch:
            raise PromptProposalMissingPatchError
        if not self.title.strip():
            raise PromptProposalTitleMissingError
        if (
            self.title != self.title.strip()
            or "\n" in self.title
            or "\r" in self.title
            or len(self.title) > 100
        ):
            raise PromptProposalTitleFormatError
        if not self.observations or any(
            not observation.strip() for observation in self.observations
        ):
            raise PromptProposalObservationsMissingError
        if not self.no_change and not self.change.strip():
            raise PromptProposalChangeMissingError
        if not self.reasoning.strip():
            raise PromptProposalReasoningMissingError

    @classmethod
    def from_file(cls, path: Path) -> "PromptProposal":
        try:
            value = msgspec.json.decode(path.read_bytes(), type=PromptProposalResponse)
        except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
            raise PromptProposalFormatError(path, error) from error

        return cls(
            value.no_change,
            value.title,
            value.observations,
            value.change,
            value.reasoning,
            value.risks,
            value.patch,
        )


class NetworkAccess(StrEnum):
    NONE = "none"
    PUBLIC = "public"


@dataclass(frozen=True)
class ProcessCapabilities:
    """The host resources an isolated child process may mutate or access."""

    writable_paths: tuple[Path, ...]
    network: NetworkAccess
    readable_paths: tuple[Path, ...] = ()
    writable_files: tuple[Path, ...] = ()
    hidden_paths: tuple[Path, ...] = ()
    unix_sockets: tuple[Path, ...] = ()


@dataclass(frozen=True)
class SecretFileDescriptor:
    """A secret supplied through a named inherited file descriptor."""

    environment_variable: str
    value: bytes = field(repr=False)


@dataclass(frozen=True)
class ProcessExchange:
    """Writes and input state produced after one process output record."""

    writes: tuple[bytes, ...] = ()
    close_input: bool = False


@dataclass(frozen=True)
class ProcessOutputRecord:
    """One child output record and the time at which it was received."""

    value: bytes
    received_at: float


@dataclass(frozen=True)
class CodexHostConfiguration:
    """Codex settings supplied by host-wide configuration layers."""

    mcp_servers: tuple[str, ...]


@dataclass(frozen=True)
class ProcessInvocation:
    command: tuple[str, ...]
    cwd: Path
    environment: dict[str, str]
    capabilities: ProcessCapabilities
    stdout: Path
    stderr: Path
    stdin: Path | None = None
    secrets: tuple[SecretFileDescriptor, ...] = ()
    deadline_seconds: float | None = None


@dataclass(frozen=True)
class ProcessResult:
    return_code: int

    @property
    def succeeded(self) -> bool:
        return self.return_code == 0


@dataclass(frozen=True)
class InstancePaths:
    root: Path
    workspace: Path
    control: Path
    candidate_state: Path
    candidate_cache: Path
    candidate_temp: Path
    judge_state: Path
    judge_cache: Path
    judge_temp: Path


@dataclass(frozen=True)
class CandidateResult:
    response: str
    transcript: Path
    trace: Path


@dataclass(frozen=True)
class VerificationResult:
    """One deterministic check, including whether a retry changed its verdict."""

    name: str
    command: tuple[str, ...]
    kind: VerificationKind
    expected_return_code: int
    return_code: int
    stdout: Path
    stderr: Path
    flaky: bool = False

    @property
    def passed(self) -> bool:
        return self.return_code == self.expected_return_code


@dataclass(frozen=True)
class WorkspaceEvidence:
    workspace: Path
    base_revision: str
    head_revision: str
    status: str
    diff: Path
    commits: Path
    changed_files: tuple[str, ...]


@dataclass(frozen=True)
class JudgementSubject:
    """The complete contextual evidence presented to a blind judge."""

    name: str
    workspace: Path
    response: str
    trace: Path
    evidence: WorkspaceEvidence
    verification: tuple[VerificationResult, ...]


@dataclass(frozen=True)
class JudgedCriterion:
    identifier: str
    passed: bool
    reason: str
    evidence: tuple[str, ...]


@dataclass(frozen=True)
class Judgement:
    criteria: tuple[JudgedCriterion, ...]
    failure_origin: FailureOrigin
    summary: str
    recommendation: str
    counterfactual: str
    corrected_response: str
    prompt_observations: tuple[str, ...]

    @classmethod
    def from_file(cls, path: Path) -> "Judgement":
        try:
            value = msgspec.json.decode(path.read_bytes(), type=JudgementResponse)
            judgement = cls(
                criteria=tuple(
                    JudgedCriterion(
                        criterion.identifier,
                        criterion.passed,
                        criterion.reason,
                        criterion.evidence,
                    )
                    for criterion in value.criteria
                ),
                failure_origin=FailureOrigin(value.failure_origin),
                summary=value.summary,
                recommendation=value.recommendation,
                counterfactual=value.counterfactual,
                corrected_response=value.corrected_response,
                prompt_observations=value.prompt_observations,
            )
        except (
            OSError,
            ValueError,
            msgspec.DecodeError,
            msgspec.ValidationError,
        ) as error:
            raise JudgementFormatError(path, error) from error

        return judgement

    def __post_init__(self) -> None:
        self.validate()

    def validate(self) -> None:
        """Require evidence for every criterion and the fields each verdict needs."""

        if not self.criteria:
            raise JudgementCriteriaEmptyError

        for criterion in self.criteria:
            if not criterion.evidence:
                raise JudgementEvidenceMissingError(criterion.identifier)

        failed = any(not criterion.passed for criterion in self.criteria)
        if not failed:
            if (
                self.failure_origin is not FailureOrigin.NONE
                or self.counterfactual
                or self.corrected_response
            ):
                raise PassingJudgementInconsistentError
            return

        if (
            self.failure_origin is FailureOrigin.NONE
            or not self.recommendation
            or not self.counterfactual
            or not self.corrected_response
        ):
            raise FailingJudgementIncompleteError

    @property
    def identifiers(self) -> tuple[str, ...]:
        """Return the judged criterion identifiers in a stable order."""

        return tuple(sorted(criterion.identifier for criterion in self.criteria))


@dataclass(frozen=True)
class CalibrationAssessment:
    candidate: str
    judgement: Judgement


@dataclass(frozen=True)
class RetainedCalibration:
    """Reference judgements and the fixture attempt whose evidence supports them."""

    assessments: tuple[CalibrationAssessment, ...]
    artefacts: Path


@dataclass(frozen=True)
class TestResult:
    candidate: CandidateResult
    evidence: WorkspaceEvidence
    verification: tuple[VerificationResult, ...]
    judgement: Judgement
    calibration: tuple[CalibrationAssessment, ...]


@dataclass(frozen=True)
class EvidenceDigest:
    """Identity of one regular file or symbolic link used by a judgement."""

    path: str
    kind: str
    digest: str
    executable: bool


@dataclass(frozen=True)
class FixtureCheckpoint:
    """Durable evidence from every expensive phase preceding final judgement."""

    candidate: CandidateResult
    subject: JudgementSubject
    calibration: tuple[CalibrationAssessment, ...]
    contract: str = ""
    evidence: tuple[EvidenceDigest, ...] = ()


class Phase(StrEnum):
    PREPARE = "prepare"
    CANDIDATE = "candidate"
    EVIDENCE = "evidence"
    VERIFY = "verify"
    CALIBRATE = "calibrate"
    JUDGE = "judge"


# The structured frontend serialises these directly, so the discriminator has
# to use the "event" key that the task records on the same stream already use.
class TestFinished(
    msgspec.Struct,
    frozen=True,
    tag="TestFinished",
    tag_field="event",
):
    fixture_name: str
    status: TestStatus
    summary: str
    failures: tuple[str, ...]
    result: TestResult | None


class SuiteFinished(
    msgspec.Struct,
    frozen=True,
    tag="SuiteFinished",
    tag_field="event",
):
    passed: int
    failed: int
    invalid: int
    stale: int
    output: Path
    run_metadata: Path


class SuiteInterrupted(
    msgspec.Struct,
    frozen=True,
    tag="SuiteInterrupted",
    tag_field="event",
):
    """Report the durable partial-result location after cancellation."""

    output: Path


class ImprovementFinished(
    msgspec.Struct,
    frozen=True,
    tag="ImprovementFinished",
    tag_field="event",
):
    """Report the bounded search outcome and its durable result location."""

    accepted_proposals: int
    attempted_proposals: int
    reserved_checks_accepted: bool
    output: Path
    winner_patch: Path | None


class ImprovementAborted(
    msgspec.Struct,
    frozen=True,
    tag="ImprovementAborted",
    tag_field="event",
):
    """Close improvement progress before the typed failure is reported."""

    output: Path


type Event = (
    TestFinished
    | SuiteFinished
    | SuiteInterrupted
    | ImprovementFinished
    | ImprovementAborted
)
