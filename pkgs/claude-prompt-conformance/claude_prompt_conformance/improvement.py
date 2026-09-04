"""Bounded prompt improvement using repeated working and reserved examples."""

import asyncio
import difflib
from collections.abc import Callable, Generator, Iterator
from concurrent.futures import (
    CancelledError,
    Future,
    ThreadPoolExecutor,
    as_completed,
)
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from typing import Protocol

import msgspec
from unidiff.errors import UnidiffParseError
from unidiff.patch import PatchSet

from .agents.improver import IMPROVER_ANGLES
from .backend import (
    FixtureRun,
    RunRequest,
    RunSummary,
    describe_running_tests,
    prepare_output,
    task_outcome,
)
from .errors import ConformanceError
from .experiments.models import (
    AcceptanceFailure,
    AcceptanceReport,
    CriterionComparison,
    CriterionScore,
    DraftReport,
    ImprovementSummary,
)
from .mcp import write_configuration
from .mcp.evaluator import McpPromptFileLimitError
from .mcp.improver import eligible_prompt_files
from .models import (
    Fixture,
    FixtureUse,
    ImprovementAborted,
    ImprovementFinished,
    PromptProposal,
    RuntimeConfiguration,
    SuiteInterrupted,
    VerificationKind,
    VerificationResult,
)
from .ports import (
    AgentSlots,
    EventSink,
    InstanceFactory,
    ProcessController,
    PromptImprover,
    PromptVariantBuilder,
)
from .progress import (
    TaskKind,
    TaskOutcome,
    TaskRun,
    TaskScopes,
    submit_in_context,
)
from .protocols.mcp import (
    CriterionOutcomeRecord,
    FixtureOutcomeRecord,
    ImproverDescriptor,
    SampleOutcomeRecord,
    VerificationOutcomeRecord,
)
from .storage import RetainedPathUnsafeError, atomic_write, ensure_directory
from .task_children import ChildAllocation, FixedTaskChildren, UnboundedTaskChildren


@dataclass(eq=True)
class PromptProposalCheckpointWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain prompt proposal checkpoint {self.destination}: {self.cause}"


@dataclass(eq=True)
class PromptPatchPathsError(ConformanceError):
    paths: tuple[Path, ...]

    def __str__(self) -> str:
        return f"the prompt patch modifies unsupported paths: {self.paths!r}"


@dataclass(eq=True)
class PromptPatchPrefixError(ConformanceError):
    endpoints: tuple[str, ...]

    def __str__(self) -> str:
        return (
            "the prompt patch omits the a/ or b/ prefix which patch strips "
            f"from: {self.endpoints!r}"
        )


@dataclass(eq=True)
class PromptPatchFormatError(ConformanceError):
    cause: Exception

    def __str__(self) -> str:
        return f"the prompt proposal is not a valid unified diff: {self.cause}"


@dataclass(eq=True)
class PromptPatchEmptyError(ConformanceError):
    def __str__(self) -> str:
        return "the prompt proposal contains no file changes"


@dataclass(eq=True)
class ImprovementProposalLimitError(ConformanceError):
    actual: int
    minimum: int
    maximum: int

    def __str__(self) -> str:
        return (
            f"improvement proposals {self.actual} are outside "
            f"{self.minimum}..{self.maximum}"
        )


@dataclass(eq=True)
class ImprovementSampleLimitError(ConformanceError):
    actual: int
    minimum: int
    maximum: int

    def __str__(self) -> str:
        return (
            f"improvement samples {self.actual} are outside "
            f"{self.minimum}..{self.maximum}"
        )


@dataclass(eq=True)
class ImprovementWorkingExamplesEmptyError(ConformanceError):
    def __str__(self) -> str:
        return "the improvement run contains no working examples"


@dataclass(eq=True)
class ImprovementReservedChecksEmptyError(ConformanceError):
    def __str__(self) -> str:
        return "the improvement run contains no reserved checks"


@dataclass(eq=True)
class ImprovementCurrentPromptInvalidError(ConformanceError):
    def __str__(self) -> str:
        return "testing the current prompt produced invalid evidence"


@dataclass(eq=True)
class ImprovementEvidenceReadError(ConformanceError):
    source: Path
    errno: int | None

    def __str__(self) -> str:
        return f"could not read prompt-improvement evidence {self.source} (errno {self.errno})"


CHECK_OUTPUT_LIMIT = 20_000
MAXIMUM_SAMPLES = 5
PATCH_PREFIXES = ("a/", "b/")
PROMPT_FILE_LIMIT = 1_000
NO_NEWLINE_MARKER = "\\ No newline at end of file\n"


class EvaluationSuite(Protocol):
    """Run one ordinary set of conformance examples."""

    def run(self, request: RunRequest) -> RunSummary: ...


class EvaluationApplication(Protocol):
    """Capabilities required for one prompt configuration."""

    @property
    def suite(self) -> EvaluationSuite: ...

    @property
    def improver(self) -> PromptImprover: ...

    @property
    def variants(self) -> PromptVariantBuilder: ...

    @property
    def instances(self) -> InstanceFactory: ...

    @property
    def processes(self) -> ProcessController: ...


@dataclass(frozen=True)
class ImprovementRequest:
    output: Path
    fixtures: tuple[Fixture, ...]
    proposals: int = 3
    samples: int = 5
    keep_workspaces: bool = False


@dataclass(frozen=True)
class DraftOutcome:
    """One tournament draft, the prompt it built, and how it was judged."""

    index: int
    identifier: str
    proposal: PromptProposal
    configuration: RuntimeConfiguration | None
    report: DraftReport | None

    @property
    def accepted(self) -> bool:
        """Return whether this draft's prompt may compete to win the round."""

        return self.report is not None and self.report.acceptance.accepted


class _CancellationScope:
    """Cancel the model processes owned by one scope and its nested scopes."""

    def __init__(self) -> None:
        self._active: dict[int, ProcessController] = {}
        self._children: list[_CancellationScope] = []
        self._cancelled = False
        self._lock = Lock()

    def reset(self) -> None:
        with self._lock:
            self._active.clear()
            self._children.clear()
            self._cancelled = False

    def child(self) -> "_CancellationScope":
        """Open a nested scope which a parent cancellation also stops."""

        scope = _CancellationScope()
        with self._lock:
            self._children.append(scope)
            cancelled = self._cancelled

        if cancelled:
            scope.cancel()
        return scope

    def close(self, scope: "_CancellationScope") -> None:
        """Forget a nested scope whose work has finished."""

        with self._lock:
            if scope in self._children:
                self._children.remove(scope)

    @contextmanager
    def track(self, processes: ProcessController) -> Generator[None]:
        with self._lock:
            identity = id(processes)
            self._active[identity] = processes
            cancelled = self._cancelled

        if cancelled:
            processes.cancel()

        try:
            yield
        finally:
            with self._lock:
                self._active.pop(identity, None)

    def cancel(self) -> None:
        with self._lock:
            self._cancelled = True
            active = tuple(self._active.values())
            children = tuple(self._children)

        for processes in active:
            processes.cancel()
        for child in children:
            child.cancel()


class _WinningPrompt:
    """Hand the tournament result to the reserved leg exactly once."""

    def __init__(self) -> None:
        self._settled: Future[RuntimeConfiguration | None] = Future()

    def settle(self, configuration: RuntimeConfiguration | None) -> None:
        """Publish the winning prompt, or its absence, to the waiting leg."""

        if not self._settled.done():
            self._settled.set_result(configuration)

    def wait(self) -> RuntimeConfiguration | None:
        """Block until the tournament has chosen a winner or given up."""

        return self._settled.result()


class PromptImprovementSuite:
    """Run one bounded improvement tournament without changing production prompts."""

    def __init__(
        self,
        applications: Callable[
            [RuntimeConfiguration, EventSink], EvaluationApplication
        ],
        events: EventSink,
        tasks: TaskScopes,
        slots: AgentSlots,
    ) -> None:
        self._applications = applications
        self._events = events
        self._tasks = tasks
        self._slots = slots
        self._processes = _CancellationScope()

    def run(
        self,
        configuration: RuntimeConfiguration,
        request: ImprovementRequest,
    ) -> ImprovementSummary:
        self._processes.reset()
        try:
            return self._run(configuration, request)
        except KeyboardInterrupt:
            self._processes.cancel()
            self._events.emit(SuiteInterrupted(request.output))
            raise
        except ConformanceError:
            self._processes.cancel()
            self._events.emit(ImprovementAborted(request.output))
            raise

    def _run(
        self,
        configuration: RuntimeConfiguration,
        request: ImprovementRequest,
    ) -> ImprovementSummary:
        validate_bounds(request)
        fixture_sets = fixtures_by_use(request.fixtures)
        validate_fixture_sets(fixture_sets)
        prepare_output(
            request.output,
            configuration.run_metadata,
            configuration.prompt_context,
        )
        with self._tasks.root(
            "prompt-improvement",
            TaskKind.IMPROVEMENT,
            "Prompt improvement",
            improvement_children(request.proposals),
        ) as root:
            return self._execute(configuration, request, fixture_sets, root)

    def _execute(
        self,
        configuration: RuntimeConfiguration,
        request: ImprovementRequest,
        fixture_sets: dict[FixtureUse, tuple[Fixture, ...]],
        root: TaskRun,
    ) -> ImprovementSummary:
        """Run the tournament while the original reserved evidence is gathered."""

        winner = _WinningPrompt()
        executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="prompt-reserved",
        )
        reserved = submit_in_context(
            executor,
            self._reserved_checks,
            configuration,
            fixture_sets[FixtureUse.RESERVED],
            request,
            winner,
        )
        try:
            drafts = self._tournament(configuration, request, fixture_sets, root)
        except BaseException:
            self._processes.cancel()
            winner.settle(None)
            executor.shutdown(wait=True)
            reserved.exception()
            raise

        best = winning_draft(drafts)
        winning_prompt = best.configuration if best is not None else None
        winner.settle(winning_prompt)
        try:
            reserved_accepted = reserved.result()
        finally:
            executor.shutdown(wait=True)

        winner_patch = None
        if winning_prompt is not None and reserved_accepted:
            winner_patch = request.output / "tries" / "winner.patch"
            atomic_write(
                request.output,
                winner_patch,
                prompt_tree_diff(
                    configuration.variant.prompt_source,
                    winning_prompt.variant.prompt_source,
                ).encode(),
            )
        summary = ImprovementSummary(
            accepted_proposals=sum(draft.accepted for draft in drafts),
            attempted_proposals=sum(not draft.proposal.no_change for draft in drafts),
            reserved_checks_accepted=reserved_accepted,
            winner=best.identifier if best is not None else None,
            winner_patch=winner_patch,
            reports=tuple(draft.report for draft in drafts if draft.report is not None),
        )
        write_improvement_summary(
            request.output,
            request.output / "improvement-summary.json",
            summary,
        )
        root.finish(
            TaskOutcome.PASSED if reserved_accepted else TaskOutcome.FAILED,
            ("Winning prompt accepted" if reserved_accepted else "No winning prompt"),
        )
        self._events.emit(
            ImprovementFinished(
                accepted_proposals=summary.accepted_proposals,
                attempted_proposals=summary.attempted_proposals,
                reserved_checks_accepted=summary.reserved_checks_accepted,
                output=request.output,
                winner_patch=summary.winner_patch,
            )
        )
        return summary

    def _tournament(
        self,
        configuration: RuntimeConfiguration,
        request: ImprovementRequest,
        fixture_sets: dict[FixtureUse, tuple[Fixture, ...]],
        root: TaskRun,
    ) -> tuple[DraftOutcome, ...]:
        """Test the current prompt, then race independent drafts against it."""

        working = fixture_sets[FixtureUse.WORKING]
        root.set_detail("Testing the current prompt")
        current_results = self._evaluate(
            configuration,
            working,
            request.output / "current-prompt",
            "current-prompt",
            "Test the current prompt",
            0,
            request,
        )
        if not summaries_have_complete_evidence(current_results):
            raise ImprovementCurrentPromptInvalidError

        root.set_detail(describe_drafting(request.proposals))
        ensure_directory(request.output, request.output / "tries")
        executor = ThreadPoolExecutor(
            max_workers=request.proposals,
            thread_name_prefix="prompt-drafts",
        )
        futures = {
            submit_in_context(
                executor,
                self._draft,
                index,
                configuration,
                current_results,
                working,
                request,
            ): index
            for index in range(1, request.proposals + 1)
        }
        outcomes: dict[int, DraftOutcome] = {}
        try:
            for future in as_completed(futures):
                outcomes[futures[future]] = future.result()
        except BaseException:
            self._processes.cancel()
            for future in futures:
                future.cancel()
            raise
        finally:
            executor.shutdown(wait=True, cancel_futures=True)

        return tuple(outcomes[index] for index in sorted(outcomes))

    def _draft(
        self,
        index: int,
        configuration: RuntimeConfiguration,
        current_results: tuple[RunSummary, ...],
        fixtures: tuple[Fixture, ...],
        request: ImprovementRequest,
    ) -> DraftOutcome:
        """Draft, build, and evaluate one competing prompt change."""

        identifier = f"draft-{index:02}"
        artefacts = request.output / "tries" / identifier
        ensure_directory(request.output, artefacts)
        with self._tasks.task(
            identifier,
            TaskKind.ITERATION,
            f"Draft {index}: drafting a prompt change",
            FixedTaskChildren(
                (
                    ChildAllocation("draft", 15),
                    ChildAllocation("build", 10),
                    ChildAllocation("proposed-prompt", 65),
                    ChildAllocation("compare", 10),
                )
            ),
            index,
        ) as task:
            task.set_detail("Drafting a prompt change")
            evidence = write_configuration(
                request.output,
                artefacts / "improver-mcp.json",
                improver_mcp_configuration(
                    configuration.variant.prompt_source,
                    current_results,
                ),
            )
            application = self._applications(configuration, self._events)
            proposal = self._propose(
                application,
                configuration,
                evidence,
                fixtures,
                artefacts,
                request.output,
                IMPROVER_ANGLES[index - 1],
            )
            task.set_description(f"Draft {index}: {proposal.title}")
            task.complete_child("draft", "Prompt change drafted")
            if proposal.no_change:
                task.complete_child("build", "No build required")
                task.complete_child("proposed-prompt", "No evaluation required")
                task.complete_child("compare", "No comparison required")
                task.finish(TaskOutcome.PASSED, "No change proposed")
                return DraftOutcome(index, identifier, proposal, None, None)

            validate_prompt_patch(proposal.patch)
            task.set_detail("Building the proposed prompt")
            variant = application.variants.build(
                configuration,
                proposal,
                artefacts / "variant",
                request.output,
            )
            task.complete_child("build", "Proposed prompt built")
            task.set_detail("Testing the proposed prompt")
            proposed_results = self._evaluate(
                variant,
                fixtures,
                artefacts / "results",
                "proposed-prompt",
                "Test the proposed prompt",
                0,
                request,
            )

            task.set_detail("Comparing prompt results")
            report = DraftReport(
                draft=identifier,
                title=proposal.title,
                acceptance=compare_results(current_results, proposed_results),
            )
            write_acceptance_report(
                request.output,
                artefacts / "acceptance.json",
                report,
            )
            task.complete_child("compare", "Results compared")
            accepted = report.acceptance.accepted
            task.finish(
                TaskOutcome.PASSED if accepted else TaskOutcome.FAILED,
                "Accepted" if accepted else "Rejected",
            )
            return DraftOutcome(index, identifier, proposal, variant, report)

    def _propose(
        self,
        application: EvaluationApplication,
        configuration: RuntimeConfiguration,
        evidence: Path,
        fixtures: tuple[Fixture, ...],
        artefacts: Path,
        root: Path,
        angle: str,
    ) -> PromptProposal:
        existing = artefacts / "prompt-proposal.json"
        completed = artefacts / ".prompt-proposal-complete"
        if existing.is_symlink() or completed.is_symlink():
            raise RetainedPathUnsafeError(
                existing if existing.is_symlink() else completed
            )
        if completed.is_file():
            return PromptProposal.from_file(existing)

        fixture, *_ = fixtures
        instance = application.instances.create("prompt-improver", artefacts)
        try:
            with self._processes.track(application.processes), self._slots.hold():
                proposal = application.improver.propose(
                    configuration,
                    evidence,
                    fixture.environment_path,
                    instance,
                    artefacts,
                    angle,
                )
            try:
                atomic_write(root, completed, b"")
            except OSError as error:
                raise PromptProposalCheckpointWriteError(completed, error) from error
            return proposal
        finally:
            application.instances.clean(instance)

    def _evaluate(
        self,
        configuration: RuntimeConfiguration,
        fixtures: tuple[Fixture, ...],
        output: Path,
        identifier: str,
        description: str,
        order: int,
        request: ImprovementRequest,
    ) -> tuple[RunSummary, ...]:
        """Run every sample of one prompt evaluation at the same time."""

        if not fixtures:
            return ()
        with self._tasks.task(
            identifier,
            TaskKind.EVALUATION,
            description,
            FixedTaskChildren.equal(
                *(f"sample-{sample:02}" for sample in range(1, request.samples + 1))
            ),
            order,
        ) as evaluation_task:
            evaluation_task.set_detail(describe_running_samples(request.samples))
            ensure_directory(request.output, output)
            scope = self._processes.child()
            executor = ThreadPoolExecutor(
                max_workers=request.samples,
                thread_name_prefix="prompt-samples",
            )
            futures = {
                submit_in_context(
                    executor,
                    self._sample,
                    configuration,
                    fixtures,
                    output,
                    sample,
                    request,
                    scope,
                ): sample
                for sample in range(1, request.samples + 1)
            }
            summaries: dict[int, RunSummary] = {}
            cancelled_for_evidence = False
            try:
                for future in as_completed(futures):
                    try:
                        summary = future.result()
                    except (CancelledError, asyncio.CancelledError):
                        # A cancelled process raises asyncio's CancelledError
                        # via RunCancelled; a future cancelled before running
                        # raises the concurrent.futures one.
                        if not cancelled_for_evidence:
                            raise
                        continue
                    summaries[futures[future]] = summary
                    if summary.invalid or summary.stale:
                        cancelled_for_evidence = True
                        scope.cancel()
            except BaseException:
                scope.cancel()
                for future in futures:
                    future.cancel()
                raise
            finally:
                executor.shutdown(wait=True, cancel_futures=True)
                self._processes.close(scope)

            ordered = tuple(summaries[sample] for sample in sorted(summaries))
            if any(summary.invalid or summary.stale for summary in ordered):
                evaluation_task.finish(TaskOutcome.INVALID, "Invalid evidence")
                return ordered

            passed = all(summary.failed == 0 for summary in ordered)
            evaluation_task.finish(
                TaskOutcome.PASSED if passed else TaskOutcome.FAILED,
                "Samples passed" if passed else "Samples failed",
            )
            return ordered

    def _sample(
        self,
        configuration: RuntimeConfiguration,
        fixtures: tuple[Fixture, ...],
        output: Path,
        sample: int,
        request: ImprovementRequest,
        scope: _CancellationScope,
    ) -> RunSummary:
        with self._tasks.task(
            f"sample-{sample:02}",
            TaskKind.SAMPLE,
            f"Sample {sample}",
            UnboundedTaskChildren(),
            sample,
        ) as sample_task:
            sample_task.set_detail(describe_running_tests(len(fixtures)))
            application = self._applications(configuration, self._events)
            with scope.track(application.processes):
                summary = application.suite.run(
                    RunRequest(
                        output=output / f"sample-{sample:02}",
                        fixtures=fixtures,
                        calibrate=sample == 1,
                        keep_workspaces=request.keep_workspaces,
                        report_suite=False,
                        store_root=request.output,
                    )
                )
            outcome = task_outcome(summary)
            sample_task.finish(outcome, sample_summary(summary))
            return summary

    def _reserved_checks(
        self,
        original: RuntimeConfiguration,
        fixtures: tuple[Fixture, ...],
        request: ImprovementRequest,
        winner: _WinningPrompt,
    ) -> bool:
        """Measure the original prompt immediately and the winner once it exists."""

        output = request.output / "reserved-checks"
        with self._tasks.task(
            "reserved-checks",
            TaskKind.EVALUATION,
            "Check the winning prompt on reserved examples",
            FixedTaskChildren(
                (
                    ChildAllocation("original-prompt", 45),
                    ChildAllocation("winning-prompt", 45),
                    ChildAllocation("compare", 10),
                )
            ),
            request.proposals + 1,
        ) as task:
            task.set_detail("Testing the original prompt")
            original_results = self._evaluate(
                original,
                fixtures,
                output / "original",
                "original-prompt",
                "Test the original prompt",
                0,
                request,
            )
            task.set_detail("Waiting for a winning prompt")
            winning = winner.wait()
            if winning is None:
                task.finish(TaskOutcome.SKIPPED, "No proposed prompt accepted")
                return False

            task.set_detail("Testing the winning prompt")
            winning_results = self._evaluate(
                winning,
                fixtures,
                output / "winning",
                "winning-prompt",
                "Test the winning prompt",
                1,
                request,
            )
            task.set_detail("Comparing results on reserved examples")
            accepted = reserved_results_accepted(original_results, winning_results)
            task.complete_child("compare", "Results compared")
            task.finish(
                TaskOutcome.PASSED if accepted else TaskOutcome.FAILED,
                "Accepted" if accepted else "Rejected",
            )
            return accepted


def improvement_children(proposals: int) -> FixedTaskChildren:
    """Reserve stable regions for the current prompt, drafts, and final check."""

    draft_weight = 60 / proposals
    return FixedTaskChildren(
        (
            ChildAllocation("current-prompt", 20),
            *(
                ChildAllocation(f"draft-{draft:02}", draft_weight)
                for draft in range(1, proposals + 1)
            ),
            ChildAllocation("reserved-checks", 20),
        )
    )


def winning_draft(drafts: tuple[DraftOutcome, ...]) -> DraftOutcome | None:
    """Select the accepted draft which improved the most criteria decisively."""

    accepted = tuple(
        (draft, draft.report.acceptance)
        for draft in drafts
        if draft.report is not None and draft.report.acceptance.accepted
    )
    if not accepted:
        return None

    winner, _ = min(
        accepted,
        key=lambda entry: (
            -entry[1].decisive_improvement,
            entry[1].noise_regressions,
            entry[0].index,
        ),
    )
    return winner


def sample_summary(summary: RunSummary) -> str:
    """Describe a completed sample using all result counts."""

    return (
        f"{summary.passed} passed, {summary.failed} failed, "
        f"{summary.invalid} invalid, {summary.stale} stale"
    )


def describe_running_samples(count: int) -> str:
    """Describe the samples owned by one prompt evaluation."""

    noun = "sample" if count == 1 else "samples"
    return f"Running {count} {noun}"


def describe_drafting(count: int) -> str:
    """Describe the competing prompt changes being drafted together."""

    noun = "prompt change" if count == 1 else "prompt changes"
    return f"Drafting {count} competing {noun}"


def validate_bounds(request: ImprovementRequest) -> None:
    if not 1 <= request.proposals <= len(IMPROVER_ANGLES):
        raise ImprovementProposalLimitError(request.proposals, 1, len(IMPROVER_ANGLES))
    if not 1 <= request.samples <= MAXIMUM_SAMPLES:
        raise ImprovementSampleLimitError(request.samples, 1, MAXIMUM_SAMPLES)


def fixtures_by_use(
    fixtures: tuple[Fixture, ...],
) -> dict[FixtureUse, tuple[Fixture, ...]]:
    return {
        use: tuple(fixture for fixture in fixtures if fixture.use is use)
        for use in FixtureUse
    }


def validate_fixture_sets(
    fixture_sets: dict[FixtureUse, tuple[Fixture, ...]],
) -> None:
    if not fixture_sets[FixtureUse.WORKING]:
        raise ImprovementWorkingExamplesEmptyError
    if not fixture_sets[FixtureUse.RESERVED]:
        raise ImprovementReservedChecksEmptyError


def validate_prompt_patch(patch: str) -> None:
    try:
        patch_set = PatchSet.from_string(patch)
    except UnidiffParseError as error:
        raise PromptPatchFormatError(error) from error

    endpoints = tuple(
        dict.fromkeys(
            endpoint
            for item in patch_set
            for endpoint in (item.source_file, item.target_file)
            if endpoint != "/dev/null"
        )
    )
    unprefixed = tuple(
        endpoint for endpoint in endpoints if not endpoint.startswith(PATCH_PREFIXES)
    )
    if unprefixed:
        raise PromptPatchPrefixError(unprefixed)

    paths = tuple(dict.fromkeys(prompt_patch_path(endpoint) for endpoint in endpoints))
    if not paths:
        raise PromptPatchEmptyError

    invalid = tuple(path for path in paths if not is_supported_prompt_path(path))
    if invalid:
        raise PromptPatchPathsError(invalid)


def prompt_patch_path(value: str) -> Path:
    """Recover the path that applying the patch with one stripped component uses."""

    for prefix in PATCH_PREFIXES:
        if value.startswith(prefix):
            return Path(value.removeprefix(prefix))
    raise PromptPatchPrefixError((value,))


def is_supported_prompt_path(path: Path) -> bool:
    """Constrain proposals to the two existing prompt source directories."""

    match path.parts:
        case ("instructions" | "output-style", *relative):
            return bool(relative) and ".." not in relative
        case _:
            return False


def criterion_scores(summaries: tuple[RunSummary, ...]) -> tuple[CriterionScore, ...]:
    """Count how often each fixture criterion passed across an evaluation."""

    counts: dict[tuple[str, str], list[bool]] = {}
    for summary in summaries:
        for run in summary.results:
            if run.result is None:
                continue
            for criterion in run.result.judgement.criteria:
                counts.setdefault((run.fixture.name, criterion.identifier), []).append(
                    criterion.passed
                )
    return tuple(
        CriterionScore(fixture, criterion, sum(results), len(results))
        for (fixture, criterion), results in sorted(counts.items())
    )


def criterion_comparisons(
    baseline: tuple[RunSummary, ...],
    proposed: tuple[RunSummary, ...],
) -> tuple[CriterionComparison, ...]:
    """Pair every criterion observed on either side of one comparison."""

    before = {
        (score.fixture, score.criterion): score for score in criterion_scores(baseline)
    }
    after = {
        (score.fixture, score.criterion): score for score in criterion_scores(proposed)
    }
    return tuple(
        CriterionComparison.between(
            before.get(key, CriterionScore.unobserved(*key)),
            after.get(key, CriterionScore.unobserved(*key)),
        )
        for key in sorted(before.keys() | after.keys())
    )


def compare_results(
    current: tuple[RunSummary, ...],
    proposed: tuple[RunSummary, ...],
) -> AcceptanceReport:
    """Accept a prompt which wins a criterion decisively and loses none.

    One criterion improving by at least three of five samples is treated as a
    real effect, while a single lost sample anywhere is treated as noise. A
    criterion which loses two or more samples rejects the prompt outright, so a
    proposal cannot buy one decisive gain with a broad, shallow decline.
    """

    comparisons = criterion_comparisons(current, proposed)
    decisive = tuple(comparison for comparison in comparisons if comparison.decisive)
    gates_improved = summaries_have_gate_failures(
        current
    ) and not summaries_have_gate_failures(proposed)
    failures: list[AcceptanceFailure] = []
    if not summaries_have_complete_evidence(proposed):
        failures.append(AcceptanceFailure.INVALID_EVIDENCE)
    if gate_failure_is_new(current, proposed):
        failures.append(AcceptanceFailure.GATE_FAILURE)
    if not decisive and not gates_improved:
        failures.append(AcceptanceFailure.NOT_IMPROVED)
    if any(comparison.regressed for comparison in comparisons):
        failures.append(AcceptanceFailure.REGRESSION)
    return AcceptanceReport(
        accepted=not failures,
        failures=tuple(failures),
        comparisons=comparisons,
        decisive_improvement=sum(comparison.change for comparison in decisive),
        noise_regressions=sum(comparison.noise for comparison in comparisons),
    )


def reserved_results_accepted(
    original: tuple[RunSummary, ...],
    winning: tuple[RunSummary, ...],
) -> bool:
    """Confirm the winner on withheld examples, using the same noise threshold."""

    return (
        summaries_have_complete_evidence(original)
        and summaries_have_complete_evidence(winning)
        and not gate_failure_is_new(original, winning)
        and not any(
            comparison.regressed
            for comparison in criterion_comparisons(original, winning)
        )
    )


def summaries_have_complete_evidence(summaries: tuple[RunSummary, ...]) -> bool:
    return bool(summaries) and all(
        summary.invalid == 0
        and summary.stale == 0
        and all(run.result is not None for run in summary.results)
        for summary in summaries
    )


def summaries_have_gate_failures(summaries: tuple[RunSummary, ...]) -> bool:
    """Report gate failures, excluding a gate quarantined by a passing retry."""

    return any(
        check.kind is VerificationKind.GATE and not check.passed
        for summary in summaries
        for run in summary.results
        if run.result is not None
        for check in run.result.verification
    )


def gate_failure_is_new(
    baseline: tuple[RunSummary, ...],
    proposed: tuple[RunSummary, ...],
) -> bool:
    """Blame a prompt for a gate failure only when it introduced one."""

    return summaries_have_gate_failures(proposed) and not summaries_have_gate_failures(
        baseline
    )


def improver_mcp_configuration(
    prompt_root: Path,
    working: tuple[RunSummary, ...],
) -> ImproverDescriptor:
    """Describe reusable working evidence for one prompt-improver instance."""

    return ImproverDescriptor(
        prompt_root=str(prompt_root),
        working=sample_outcomes(working),
    )


def sample_outcomes(
    summaries: tuple[RunSummary, ...],
) -> tuple[SampleOutcomeRecord, ...]:
    return tuple(
        SampleOutcomeRecord(
            sample=sample,
            outcomes=tuple(fixture_outcome(run) for run in summary.results),
        )
        for sample, summary in enumerate(summaries, start=1)
    )


def fixture_outcome(run: FixtureRun) -> FixtureOutcomeRecord:
    if run.result is None:
        return FixtureOutcomeRecord(
            fixture=run.fixture.name,
            status=run.status.value,
            error_type=type(run.error).__name__ if run.error is not None else None,
            criteria=(),
            checks=(),
            failure_origin=None,
            summary=None,
            recommendation=None,
            prompt_observations=(),
        )
    judgement = run.result.judgement
    return FixtureOutcomeRecord(
        fixture=run.fixture.name,
        status=run.status.value,
        error_type=None,
        criteria=tuple(
            CriterionOutcomeRecord(
                identifier=criterion.identifier,
                passed=criterion.passed,
                reason=criterion.reason,
                evidence=criterion.evidence,
            )
            for criterion in judgement.criteria
        ),
        checks=tuple(verification_outcome(check) for check in run.result.verification),
        failure_origin=judgement.failure_origin.value,
        summary=judgement.summary,
        recommendation=judgement.recommendation,
        prompt_observations=judgement.prompt_observations,
    )


def verification_outcome(check: VerificationResult) -> VerificationOutcomeRecord:
    stdout, stdout_truncated = bounded_evidence(check.stdout, CHECK_OUTPUT_LIMIT)
    stderr, stderr_truncated = bounded_evidence(check.stderr, CHECK_OUTPUT_LIMIT)
    return VerificationOutcomeRecord(
        name=check.name,
        command=check.command,
        kind=check.kind.value,
        expected_return_code=check.expected_return_code,
        return_code=check.return_code,
        passed=check.passed,
        flaky=check.flaky,
        stdout=stdout,
        stdout_truncated=stdout_truncated,
        stderr=stderr,
        stderr_truncated=stderr_truncated,
    )


def bounded_evidence(source: Path, limit: int) -> tuple[str, bool]:
    """Read bounded retained evidence without assuming it contains UTF-8 text."""

    try:
        with source.open("rb") as stream:
            contents = stream.read(limit + 1)
    except OSError as error:
        raise ImprovementEvidenceReadError(source, error.errno) from error

    return contents[:limit].decode(errors="replace"), len(contents) > limit


def write_acceptance_report(
    root: Path,
    path: Path,
    report: DraftReport,
) -> None:
    atomic_write(root, path, msgspec.json.encode(report))


def write_improvement_summary(
    root: Path,
    path: Path,
    summary: ImprovementSummary,
) -> None:
    atomic_write(
        root,
        path,
        msgspec.json.encode(
            summary,
            enc_hook=encode_path,
        ),
    )


def encode_path(value: object) -> str:
    """Encode path-like domain values at the JSON artefact boundary."""

    if not isinstance(value, Path):
        raise TypeError
    return value.as_posix()


def prompt_tree_diff(base: Path, variant: Path) -> str:
    """Describe every accepted prompt change the improver was able to make."""

    relative_paths = sorted(
        set(prompt_tree_files(base)) | set(prompt_tree_files(variant))
    )
    return "".join(
        chunk
        for relative in relative_paths
        for chunk in file_diff(
            read_optional(base / relative),
            read_optional(variant / relative),
            relative,
        )
    )


def prompt_tree_files(root: Path) -> tuple[str, ...]:
    """List the prompt files a proposal may change, exactly as the improver sees them."""

    files, truncated = eligible_prompt_files(root, PROMPT_FILE_LIMIT)
    if truncated:
        raise McpPromptFileLimitError(root, PROMPT_FILE_LIMIT)
    return files


def file_diff(before: list[str], after: list[str], relative: str) -> Iterator[str]:
    """Emit one file's unified diff, marking an absent trailing newline."""

    for line in difflib.unified_diff(
        before,
        after,
        fromfile=f"a/{relative}",
        tofile=f"b/{relative}",
    ):
        if line.endswith("\n"):
            yield line
            continue
        yield f"{line}\n"
        yield NO_NEWLINE_MARKER


def read_optional(path: Path) -> list[str]:
    try:
        return path.read_text().splitlines(keepends=True)
    except FileNotFoundError:
        return []
