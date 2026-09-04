"""Read-only MCP capabilities for one prompt-improvement proposal."""

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Annotated

from mcp.server.fastmcp import FastMCP
from pydantic import Field

from ..errors import ConformanceError
from ..protocols.mcp import (
    FixtureOutcomeRecord,
    ImproverDescriptor,
    SampleOutcomeRecord,
    VerificationOutcomeRecord,
)
from .files import McpPathOutsideRootError, list_files, logical_child, read_page
from .models import (
    CriterionOutcome,
    CriterionScoreSummary,
    FailureDetail,
    FailureListing,
    FailureReference,
    FileListing,
    ImprovementOverview,
    TextPage,
    VerificationOutcome,
    WorkingExamplesSummary,
)


@dataclass(eq=True)
class McpUnknownFailureError(ConformanceError):
    sample: int
    fixture: str

    def __str__(self) -> str:
        return (
            f"no failed outcome exists for sample {self.sample} and fixture "
            f"{self.fixture!r}"
        )


PageOffset = Annotated[int, Field(ge=0)]
PageLimit = Annotated[int, Field(ge=1, le=20_000)]
PROMPT_DIRECTORIES = ("instructions", "output-style")


class ImproverEvidence:
    """Provide working evidence and prompt sources to one fresh improver."""

    def __init__(self, configuration: ImproverDescriptor) -> None:
        self._configuration = configuration

    def overview(self) -> ImprovementOverview:
        return ImprovementOverview(
            working=working_examples_summary(self._configuration.working),
            scores=working_criterion_scores(self._configuration.working),
        )

    def failures(self) -> FailureListing:
        return FailureListing(
            failures=tuple(
                failure_reference(sample.sample, outcome)
                for sample in self._configuration.working
                for outcome in sample.outcomes
                if outcome.status != "passed"
                or any(not criterion.passed for criterion in outcome.criteria)
            )
        )

    def failure(self, sample: int, fixture: str) -> FailureDetail:
        try:
            outcome = next(
                outcome
                for item in self._configuration.working
                if item.sample == sample
                for outcome in item.outcomes
                if outcome.fixture == fixture
                and (
                    outcome.status != "passed"
                    or any(not criterion.passed for criterion in outcome.criteria)
                )
            )
        except StopIteration as error:
            raise McpUnknownFailureError(sample, fixture) from error
        return failure_detail(sample, outcome)

    def prompt_files(self) -> FileListing:
        root = Path(self._configuration.prompt_root)
        files, truncated = eligible_prompt_files(root, 1_000)
        return FileListing(
            root="prompt-source",
            offset=0,
            next_offset=None,
            files=files,
            truncated=truncated,
        )

    def prompt_file(self, path: str, offset: int, limit: int) -> TextPage:
        root = Path(self._configuration.prompt_root)
        source = logical_child(root, path)
        permitted, _ = eligible_prompt_files(root, 1_000_000)
        if path not in permitted:
            raise McpPathOutsideRootError(root, path)
        return read_page(source, offset, limit, display_path=path)


def create_improver_server(evidence: ImproverEvidence) -> FastMCP[None]:
    """Register the improver's schema-backed evidence tools."""

    server: FastMCP[None] = FastMCP(
        "prompt-conformance-improver",
        instructions=(
            "Use these read-only tools to inspect working outcomes and the prompt "
            "sources eligible for a general improvement."
        ),
    )

    @server.tool()
    def get_improvement_overview() -> ImprovementOverview:
        """Return working-example totals and outcomes of earlier proposals."""

        return evidence.overview()

    @server.tool()
    def list_failures() -> FailureListing:
        """List failed or invalid working-example outcomes."""

        return evidence.failures()

    @server.tool()
    def get_failure(
        sample: Annotated[int, Field(ge=1)],
        fixture: str,
    ) -> FailureDetail:
        """Return detailed evidence for one failed working example."""

        return evidence.failure(sample, fixture)

    @server.tool()
    def list_prompt_files() -> FileListing:
        """List prompt instruction and output-style files eligible for changes."""

        return evidence.prompt_files()

    @server.tool()
    def read_prompt_file(
        path: str,
        offset: PageOffset = 0,
        limit: PageLimit = 20_000,
    ) -> TextPage:
        """Read a page from one listed prompt source file."""

        return evidence.prompt_file(path, offset, limit)

    return server


def eligible_prompt_files(root: Path, limit: int) -> tuple[tuple[str, ...], bool]:
    """List only prompt sources which a proposal is allowed to modify."""

    files: list[str] = []
    for directory in PROMPT_DIRECTORIES:
        remaining = limit - len(files)
        if remaining == 0:
            return tuple(files), True
        prefix = PurePosixPath(directory)
        selected, truncated = list_files(root / directory, prefix, remaining)
        files.extend(selected)
        if truncated:
            return tuple(files), True
    return tuple(files), False


def working_examples_summary(
    samples: tuple[SampleOutcomeRecord, ...],
) -> WorkingExamplesSummary:
    """Summarise complete working outcomes for model-guided triage."""

    outcomes = tuple(outcome for sample in samples for outcome in sample.outcomes)
    return WorkingExamplesSummary(
        samples=len(samples),
        outcomes=len(outcomes),
        passed=sum(outcome.status == "passed" for outcome in outcomes),
        failed=sum(outcome.status == "failed" for outcome in outcomes),
        invalid=sum(outcome.status == "invalid" for outcome in outcomes),
    )


def working_criterion_scores(
    samples: tuple[SampleOutcomeRecord, ...],
) -> tuple[CriterionScoreSummary, ...]:
    """Aggregate every working sample into per-criterion pass counts."""

    counts: dict[tuple[str, str], list[bool]] = {}
    for sample in samples:
        for outcome in sample.outcomes:
            for criterion in outcome.criteria:
                counts.setdefault((outcome.fixture, criterion.identifier), []).append(
                    criterion.passed
                )
    return tuple(
        CriterionScoreSummary(
            fixture=fixture,
            criterion=criterion,
            passed=sum(results),
            total=len(results),
        )
        for (fixture, criterion), results in sorted(counts.items())
    )


def failure_reference(sample: int, value: FixtureOutcomeRecord) -> FailureReference:
    """Identify one failed result for selective detail retrieval."""

    return FailureReference(
        sample=sample,
        fixture=value.fixture,
        status=value.status,
        failed_criteria=tuple(
            criterion.identifier for criterion in value.criteria if not criterion.passed
        ),
        failed_checks=tuple(check.name for check in value.checks if not check.passed),
    )


def failure_detail(sample: int, value: FixtureOutcomeRecord) -> FailureDetail:
    """Expose the evaluator's complete structured account of one failure."""

    return FailureDetail(
        sample=sample,
        fixture=value.fixture,
        status=value.status,
        error_type=value.error_type,
        criteria=tuple(
            CriterionOutcome(
                identifier=criterion.identifier,
                passed=criterion.passed,
                reason=criterion.reason,
                evidence=criterion.evidence,
            )
            for criterion in value.criteria
        ),
        checks=tuple(verification_outcome(check) for check in value.checks),
        failure_origin=value.failure_origin,
        summary=value.summary,
        recommendation=value.recommendation,
        prompt_observations=value.prompt_observations,
    )


def verification_outcome(value: VerificationOutcomeRecord) -> VerificationOutcome:
    """Expose one bounded deterministic check to the prompt improver."""

    return VerificationOutcome(
        name=value.name,
        command=value.command,
        kind=value.kind,
        expected_return_code=value.expected_return_code,
        return_code=value.return_code,
        passed=value.passed,
        flaky=value.flaky,
        stdout=value.stdout,
        stdout_truncated=value.stdout_truncated,
        stderr=value.stderr,
        stderr_truncated=value.stderr_truncated,
    )
