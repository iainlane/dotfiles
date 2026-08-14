"""Frontend-independent orchestration for repository prompt conformance."""

import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import AbstractContextManager
from dataclasses import dataclass, replace
from pathlib import Path

import msgspec

from .checkpoints import judge_identity
from .errors import ConformanceError, RetainedStateError
from .models import (
    CalibrationAssessment,
    CalibrationCandidate,
    CandidateResult,
    Fixture,
    FixtureCheckpoint,
    InstancePaths,
    Judgement,
    JudgementCriteriaError,
    JudgementSubject,
    Phase,
    RetainedCalibration,
    SuiteFinished,
    SuiteInterrupted,
    TestFinished,
    TestResult,
    TestStatus,
    VerificationKind,
    VerificationResult,
    WorkspaceEvidence,
)
from .ports import (
    AgentSlots,
    CandidateAgent,
    EventSink,
    FixtureResultStore,
    InstanceFactory,
    Judge,
    ProcessController,
    RepositoryMaterialiser,
    Verifier,
    WorkspaceInspector,
    WorkspaceOverlay,
    WorkspacePreparer,
)
from .progress import (
    TaskKind,
    TaskOutcome,
    TaskRun,
    TaskScopes,
    current_task,
    submit_in_context,
)
from .protocols.configuration import FixtureInput
from .run_store import (
    OutputPathNotDirectoryError,
    OutputPathUnmarkedError,
    OutputSnapshotMismatchError,
    ProtectedOutputPathError,
)
from .storage import (
    OUTPUT_MARKER,
    atomic_write,
    directory_exists,
    directory_identity,
    ensure_directory,
    remove_identified_directory,
)
from .task_children import ChildAllocation, FixedTaskChildren, UnboundedTaskChildren


@dataclass(eq=True)
class FixtureManifestFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"fixture manifest {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class UnknownFixtureSelectionError(ConformanceError):
    name: str

    def __str__(self) -> str:
        return f"unknown test {self.name!r}"


@dataclass(eq=True)
class EmptyFixtureSelectionError(ConformanceError):
    def __str__(self) -> str:
        return "selection matched no tests"


@dataclass(eq=True)
class RunMetadataSnapshotError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain run metadata from {self.source}: {self.cause}"


@dataclass(eq=True)
class PromptContextSnapshotError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain prompt context from {self.source}: {self.cause}"


@dataclass(eq=True)
class CalibrationCriteriaMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the fixture has no criteria available for calibration"


@dataclass(frozen=True)
class VerificationFailure:
    name: str
    expected_return_code: int
    actual_return_code: int

    def __str__(self) -> str:
        return (
            f"{self.name}: expected exit {self.expected_return_code}, "
            f"received {self.actual_return_code}"
        )


@dataclass(frozen=True)
class CriterionExpectationMismatch:
    subject: str
    expected: tuple[tuple[str, bool], ...]
    actual: tuple[tuple[str, bool], ...]

    def __str__(self) -> str:
        return f"judge calibration disagreed for {self.subject}"


@dataclass(eq=True)
class CalibrationMismatchError(ConformanceError):
    mismatches: tuple[CriterionExpectationMismatch, ...]

    def __str__(self) -> str:
        return "; ".join(str(mismatch) for mismatch in self.mismatches)


@dataclass(eq=True)
class ReferenceVerificationError(ConformanceError):
    subject: str
    failures: tuple[VerificationFailure, ...]

    def __str__(self) -> str:
        return (
            f"reference subject {self.subject} failed deterministic gates: "
            + "; ".join(str(failure) for failure in self.failures)
        )


@dataclass(frozen=True)
class Selection:
    names: tuple[str, ...] = ()
    categories: tuple[str, ...] = ()
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class RunRequest:
    output: Path
    fixtures: tuple[Fixture, ...]
    calibrate: bool = True
    keep_workspaces: bool = False
    report_suite: bool = True
    store_root: Path | None = None


@dataclass(frozen=True)
class RunSummary:
    passed: int
    failed: int
    invalid: int
    stale: int
    results: tuple["FixtureRun", ...]


@dataclass(frozen=True)
class CalibrationContext:
    """Where a fixture's calibration is retained and which judge produced it."""

    store_root: Path
    judge: str
    retained: RetainedCalibration | None

    def holds_evidence(self, artefacts: Path) -> bool:
        """Test whether one fixture attempt holds the evidence being reused."""

        retained = self.retained
        return retained is not None and retained.artefacts == artefacts.resolve()


@dataclass(frozen=True)
class FixtureRun:
    """The complete terminal outcome of one fixture execution."""

    fixture: Fixture
    status: TestStatus
    artefacts: Path
    failures: tuple[str, ...]
    result: TestResult | None
    error: ConformanceError | None


class ConformanceSuite:
    """Coordinate injected capabilities across candidate and calibration runs."""

    def __init__(
        self,
        instances: InstanceFactory,
        repositories: RepositoryMaterialiser,
        overlay: WorkspaceOverlay,
        preparer: WorkspacePreparer,
        candidate: CandidateAgent,
        inspector: WorkspaceInspector,
        verifier: Verifier,
        judge: Judge,
        events: EventSink,
        tasks: TaskScopes,
        processes: ProcessController,
        slots: AgentSlots,
        results: FixtureResultStore,
        run_metadata: Path,
        prompt_context: Path,
    ) -> None:
        self._instances = instances
        self._repositories = repositories
        self._overlay = overlay
        self._preparer = preparer
        self._candidate = candidate
        self._inspector = inspector
        self._verifier = verifier
        self._judge = judge
        self._events = events
        self._tasks = tasks
        self._processes = processes
        self._slots = slots
        self._results = results
        self._run_metadata = run_metadata
        self._prompt_context = prompt_context

    def run(self, request: RunRequest) -> RunSummary:
        if not request.fixtures:
            raise EmptyFixtureSelectionError

        try:
            with self._suite_task(request) as suite_task:
                return self._run(request, suite_task)
        except KeyboardInterrupt:
            if request.report_suite:
                self._events.emit(SuiteInterrupted(output=request.output))
            raise

    def _run(self, request: RunRequest, suite_task: TaskRun) -> RunSummary:
        prepare_output(
            request.output,
            self._run_metadata,
            self._prompt_context,
            root=request.store_root,
        )
        suite_task.set_detail(describe_running_tests(len(request.fixtures)))
        executor = ThreadPoolExecutor(
            max_workers=len(request.fixtures),
            thread_name_prefix="prompt-conformance",
        )
        futures = tuple(
            submit_in_context(executor, self._run_fixture, fixture, request, index)
            for index, fixture in enumerate(request.fixtures)
        )
        results: list[FixtureRun] = []
        try:
            for future in as_completed(futures):
                result = future.result()
                results.append(result)
        except BaseException:
            self._processes.cancel()
            for future in futures:
                future.cancel()
            raise
        finally:
            executor.shutdown(wait=True, cancel_futures=True)

        summary = RunSummary(
            passed=sum(result.status is TestStatus.PASSED for result in results),
            failed=sum(result.status is TestStatus.FAILED for result in results),
            invalid=sum(result.status is TestStatus.INVALID for result in results),
            stale=sum(result.status is TestStatus.STALE for result in results),
            results=tuple(sorted(results, key=lambda result: result.fixture.name)),
        )
        suite_task.finish(
            task_outcome(summary),
            suite_summary(summary),
        )
        if request.report_suite:
            self._events.emit(
                SuiteFinished(
                    passed=summary.passed,
                    failed=summary.failed,
                    invalid=summary.invalid,
                    stale=summary.stale,
                    output=request.output,
                    run_metadata=self._run_metadata,
                )
            )
        return summary

    def _suite_task(self, request: RunRequest) -> AbstractContextManager[TaskRun]:
        if current_task() is None:
            return self._tasks.root(
                "conformance",
                TaskKind.SUITE,
                "Prompt conformance",
                FixedTaskChildren.equal(
                    *(fixture.name for fixture in request.fixtures)
                ),
            )

        return self._tasks.task(
            "suite",
            TaskKind.SUITE,
            "Prompt conformance",
            FixedTaskChildren.equal(*(fixture.name for fixture in request.fixtures)),
            0,
        )

    def _run_fixture(
        self,
        fixture: Fixture,
        request: RunRequest,
        order: int,
    ) -> FixtureRun:
        with self._tasks.task(
            fixture.name,
            TaskKind.FIXTURE,
            fixture.description,
            fixture_children(request.calibrate),
            order,
        ) as task:
            return self._execute_fixture(fixture, request, task)

    def _execute_fixture(
        self,
        fixture: Fixture,
        request: RunRequest,
        task: TaskRun,
    ) -> FixtureRun:
        artefacts = request.output / fixture.name
        store_root = request.store_root or request.output
        instance: InstancePaths | None = None
        retain_instance = request.keep_workspaces

        try:
            stored = self._results.load(
                store_root,
                fixture,
                artefacts,
                calibrate=request.calibrate,
            )
            if isinstance(stored, TestResult):
                return self._reuse_result(
                    fixture,
                    artefacts,
                    stored,
                    request.calibrate,
                    task,
                )

            if isinstance(stored, FixtureCheckpoint):
                instance = self._instances.create("candidate", artefacts)
                return self._resume_checkpoint(
                    fixture,
                    artefacts,
                    instance,
                    stored,
                    request,
                    task,
                )

            context = self._calibration_context(
                store_root,
                fixture,
                request.calibrate,
            )
            self._results.reset(
                store_root,
                artefacts,
                retain_calibration=context.holds_evidence(artefacts),
            )
            instance = self._instances.create("candidate", artefacts)
            task.set_detail("Preparing an isolated checkout")
            self._prepare(fixture, instance, artefacts)
            calibration: tuple[CalibrationAssessment, ...] = ()
            if request.calibrate:
                calibration = self._calibration(fixture, artefacts, context, task)
            task.set_detail("Asking the candidate agent")
            candidate = self._run_candidate(fixture, instance, artefacts)
            task.set_detail("Capturing the candidate work")
            evidence = self._inspect(fixture, instance, artefacts)
            task.set_detail("Running deterministic checks")
            verification = self._verify(fixture, instance, artefacts)
            task.set_detail("Asking the independent judge")
            subject = JudgementSubject(
                name="candidate",
                workspace=evidence.workspace,
                response=candidate.response,
                trace=candidate.trace,
                evidence=evidence,
                verification=verification,
            )
            self._results.save_checkpoint(
                store_root,
                fixture,
                artefacts,
                FixtureCheckpoint(candidate, subject, calibration),
            )
            judgement = self._judge_subject(
                fixture,
                subject,
                instance,
                artefacts,
            )
            result = TestResult(
                candidate=candidate,
                evidence=evidence,
                verification=verification,
                judgement=judgement,
                calibration=calibration,
            )
            self._results.save_result(
                store_root,
                fixture,
                artefacts,
                result,
            )
            return self._finish_result(fixture, artefacts, result, task)
        except RetainedStateError as error:
            retain_instance = True
            return self._abandon(fixture, artefacts, TestStatus.STALE, error, task)
        except ConformanceError as error:
            retain_instance = True
            return self._abandon(fixture, artefacts, TestStatus.INVALID, error, task)
        except KeyboardInterrupt:
            retain_instance = True
            raise
        finally:
            if instance is not None and not retain_instance:
                self._instances.clean(instance)

    def _abandon(
        self,
        fixture: Fixture,
        artefacts: Path,
        status: TestStatus,
        error: ConformanceError,
        task: TaskRun,
    ) -> FixtureRun:
        """Report one fixture which reached no judgement, without a traceback."""

        self._events.emit(
            TestFinished(
                fixture_name=fixture.name,
                status=status,
                summary=str(error),
                failures=(str(error),),
                result=None,
            )
        )
        task.finish(TaskOutcome.INVALID, str(error))
        return FixtureRun(
            fixture,
            status,
            artefacts,
            (str(error),),
            None,
            error,
        )

    def _resume_checkpoint(
        self,
        fixture: Fixture,
        artefacts: Path,
        instance: InstancePaths,
        checkpoint: FixtureCheckpoint,
        request: RunRequest,
        task: TaskRun,
    ) -> FixtureRun:
        """Continue at the first model boundary not durably completed."""

        self._complete_checkpoint_phases(task, checkpoint, request.calibrate)
        task.set_detail("Asking the independent judge")
        judgement = self._judge_subject(
            fixture,
            checkpoint.subject,
            instance,
            artefacts,
        )
        result = TestResult(
            candidate=checkpoint.candidate,
            evidence=checkpoint.subject.evidence,
            verification=checkpoint.subject.verification,
            judgement=judgement,
            calibration=checkpoint.calibration,
        )
        self._results.save_result(
            request.store_root or request.output,
            fixture,
            artefacts,
            result,
        )
        return self._finish_result(fixture, artefacts, result, task)

    def _reuse_result(
        self,
        fixture: Fixture,
        artefacts: Path,
        result: TestResult,
        calibrate: bool,
        task: TaskRun,
    ) -> FixtureRun:
        """Present a structurally validated terminal result without reevaluation."""

        checkpoint = FixtureCheckpoint(
            result.candidate,
            JudgementSubject(
                name="candidate",
                workspace=result.evidence.workspace,
                response=result.candidate.response,
                trace=result.candidate.trace,
                evidence=result.evidence,
                verification=result.verification,
            ),
            result.calibration,
        )
        self._complete_checkpoint_phases(task, checkpoint, calibrate)
        task.complete_child(Phase.JUDGE.value, "Reused completed judgement")
        return self._finish_result(fixture, artefacts, result, task)

    def _complete_checkpoint_phases(
        self,
        task: TaskRun,
        checkpoint: FixtureCheckpoint,
        calibrate: bool,
    ) -> None:
        task.complete_child(Phase.PREPARE.value, "Reused prepared checkout")
        if calibrate:
            task.complete_child(
                Phase.CALIBRATE.value,
                describe_calibration(len(checkpoint.calibration), 0),
            )
        task.complete_child(Phase.CANDIDATE.value, "Reused candidate response")
        task.complete_child(
            Phase.EVIDENCE.value,
            describe_captured_work(len(checkpoint.subject.evidence.changed_files)),
        )
        failed = sum(not result.passed for result in checkpoint.subject.verification)
        task.complete_child(
            Phase.VERIFY.value,
            describe_verification(
                len(checkpoint.subject.verification) - failed,
                failed,
                sum(result.flaky for result in checkpoint.subject.verification),
            ),
        )

    def _finish_result(
        self,
        fixture: Fixture,
        artefacts: Path,
        result: TestResult,
        task: TaskRun,
    ) -> FixtureRun:
        failures = judgement_failures(result.judgement)
        failures.extend(
            str(item) for item in verification_gate_failures(result.verification)
        )
        status = TestStatus.PASSED if not failures else TestStatus.FAILED
        self._events.emit(
            TestFinished(
                fixture_name=fixture.name,
                status=status,
                summary=result.judgement.summary,
                failures=tuple(failures),
                result=result,
            )
        )
        task.finish(
            TaskOutcome.PASSED if status is TestStatus.PASSED else TaskOutcome.FAILED,
            result.judgement.summary,
        )
        return FixtureRun(
            fixture,
            status,
            artefacts,
            tuple(failures),
            result,
            None,
        )

    def _prepare(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> None:
        description = "Preparing an isolated checkout"
        with self._tasks.task(
            Phase.PREPARE.value,
            TaskKind.PHASE,
            description,
            UnboundedTaskChildren(),
            0,
        ) as task:
            self._repositories.materialise(
                fixture.repository,
                instance.workspace,
                instance.control,
                fixture.environment_path,
                fixture.comparison_revision,
            )
            self._overlay.install(instance.workspace)
            self._preparer.prepare(fixture, instance, artefacts)
            task.finish(TaskOutcome.COMPLETED, "Checkout prepared")

    def _run_candidate(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> CandidateResult:
        description = "Asking the candidate agent"
        with self._tasks.task(
            Phase.CANDIDATE.value,
            TaskKind.PHASE,
            description,
            UnboundedTaskChildren(),
            2,
        ) as task:
            task.set_detail("Waiting for an agent slot")
            with self._slots.hold():
                task.set_detail(description)
                result = self._candidate.run(fixture, instance, artefacts, task)
            (artefacts / "response.md").write_text(result.response)
            task.finish(TaskOutcome.COMPLETED, "Candidate response received")
            return result

    def _verify(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> tuple[VerificationResult, ...]:
        description = "Running deterministic checks"
        with self._tasks.task(
            Phase.VERIFY.value,
            TaskKind.PHASE,
            description,
            UnboundedTaskChildren(),
            4,
        ) as task:
            results = self._verifier.verify(fixture, instance, artefacts)
            passed = sum(item.passed for item in results)
            failed = len(results) - passed
            task.finish(
                TaskOutcome.PASSED if failed == 0 else TaskOutcome.FAILED,
                describe_verification(
                    passed,
                    failed,
                    sum(item.flaky for item in results),
                ),
            )
            return results

    def _inspect(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> WorkspaceEvidence:
        description = "Capturing the candidate work"
        with self._tasks.task(
            Phase.EVIDENCE.value,
            TaskKind.PHASE,
            description,
            UnboundedTaskChildren(),
            3,
        ) as task:
            evidence = self._inspector.inspect(
                instance.workspace,
                fixture.comparison_revision,
                artefacts,
                fixture.environment_path,
            )
            task.finish(
                TaskOutcome.COMPLETED,
                describe_captured_work(len(evidence.changed_files)),
            )
            return evidence

    def _calibration_context(
        self,
        store_root: Path,
        fixture: Fixture,
        calibrate: bool,
    ) -> CalibrationContext:
        """Recover completed calibration before an incomplete attempt is reset."""

        if not calibrate:
            return CalibrationContext(store_root, "", None)

        judge = judge_identity(self._run_metadata)
        return CalibrationContext(
            store_root,
            judge,
            self._results.load_calibration(store_root, fixture, judge=judge),
        )

    def _calibration(
        self,
        fixture: Fixture,
        artefacts: Path,
        context: CalibrationContext,
        task: TaskRun,
    ) -> tuple[CalibrationAssessment, ...]:
        """Calibrate the judge once per run store, before any candidate work."""

        retained = context.retained
        if retained is not None:
            task.complete_child(
                Phase.CALIBRATE.value,
                describe_calibration(len(retained.assessments), 0),
            )
            return retained.assessments

        task.set_detail("Calibrating the judge")
        calibration = self._calibrate(fixture, artefacts)
        failures = calibration_failures(fixture, calibration)
        if failures:
            raise CalibrationMismatchError(failures)
        self._results.save_calibration(
            context.store_root,
            fixture,
            artefacts,
            calibration,
            judge=context.judge,
        )
        return calibration

    def _calibrate(
        self,
        fixture: Fixture,
        artefacts: Path,
    ) -> tuple[CalibrationAssessment, ...]:
        description = "Calibrating the judge"
        with self._tasks.task(
            Phase.CALIBRATE.value,
            TaskKind.PHASE,
            description,
            FixedTaskChildren.equal(
                *(
                    f"subject-{index:02}"
                    for index in range(1, len(fixture.calibration) + 1)
                )
            ),
            1,
        ) as calibration_task:
            assessments = self._calibration_assessments(
                fixture,
                artefacts,
                calibration_task,
            )
            failed = len(calibration_failures(fixture, assessments))
            passed = len(assessments) - failed
            calibration_task.finish(
                TaskOutcome.PASSED if failed == 0 else TaskOutcome.FAILED,
                describe_calibration(passed, failed),
            )
            return assessments

    def _calibration_assessments(
        self,
        fixture: Fixture,
        artefacts: Path,
        calibration_task: TaskRun,
    ) -> tuple[CalibrationAssessment, ...]:
        """Judge every reference subject of one fixture at the same time."""

        calibration_root = artefacts / "calibration"
        calibration_root.mkdir()
        calibrated_fixture = replace(
            fixture,
            criteria=tuple(
                criterion for criterion in fixture.criteria if criterion.calibrate
            ),
        )
        if not calibrated_fixture.criteria:
            raise CalibrationCriteriaMissingError

        calibration_task.set_detail(
            describe_reference_subjects(len(fixture.calibration))
        )
        executor = ThreadPoolExecutor(
            max_workers=len(fixture.calibration),
            thread_name_prefix="prompt-calibration",
        )
        futures = {
            submit_in_context(
                executor,
                self._calibration_subject,
                calibrated_fixture,
                fixture,
                candidate,
                calibration_root,
                index,
            ): index
            for index, candidate in enumerate(fixture.calibration, start=1)
        }
        assessments: dict[int, CalibrationAssessment] = {}
        try:
            for future in as_completed(futures):
                assessments[futures[future]] = future.result()
        except BaseException:
            for future in futures:
                future.cancel()
            raise
        finally:
            executor.shutdown(wait=True, cancel_futures=True)

        return tuple(assessments[index] for index in sorted(assessments))

    def _calibration_subject(
        self,
        calibrated_fixture: Fixture,
        fixture: Fixture,
        candidate: CalibrationCandidate,
        calibration_root: Path,
        index: int,
    ) -> CalibrationAssessment:
        """Prepare, check, and blindly judge one opaque reference subject."""

        opaque_name = f"subject-{index:02}"
        candidate_artefacts = calibration_root / opaque_name
        candidate_artefacts.mkdir()
        instance = self._instances.create("instance", candidate_artefacts)
        try:
            with self._tasks.task(
                opaque_name,
                TaskKind.PHASE,
                f"Reference subject {index}",
                FixedTaskChildren(
                    (
                        ChildAllocation("prepare", 10),
                        ChildAllocation("evidence", 10),
                        ChildAllocation("verify", 15),
                        ChildAllocation("judge", 65),
                    )
                ),
                index - 1,
            ) as subject_task:
                subject_task.set_detail("Preparing the reference repository")
                self._repositories.materialise(
                    candidate.repository,
                    instance.workspace,
                    instance.control,
                    fixture.environment_path,
                    fixture.comparison_revision,
                )
                self._overlay.install(instance.workspace)
                self._preparer.prepare(fixture, instance, candidate_artefacts)
                subject_task.complete_child("prepare", "Reference repository prepared")

                subject_task.set_detail("Capturing the reference work")
                evidence = self._inspector.inspect(
                    instance.workspace,
                    fixture.comparison_revision,
                    candidate_artefacts,
                    fixture.environment_path,
                )
                subject_task.complete_child("evidence", "Reference evidence captured")

                subject_task.set_detail("Running reference checks")
                verification = self._verifier.verify(
                    fixture, instance, candidate_artefacts
                )
                gate_failures = verification_gate_failures(verification)
                expected_passes = dict(candidate.expected_criteria)
                if all(expected_passes.values()) and gate_failures:
                    raise ReferenceVerificationError(opaque_name, gate_failures)
                subject_task.complete_child("verify", "Reference checks finished")

                subject_task.set_detail("Asking the independent judge")
                trace = candidate_artefacts / "actions.json"
                trace.write_text("[]")
                judgement = self._judge_subject(
                    calibrated_fixture,
                    JudgementSubject(
                        name=opaque_name,
                        workspace=evidence.workspace,
                        response=candidate.response.read_text(),
                        trace=trace,
                        evidence=evidence,
                        verification=verification,
                    ),
                    instance,
                    candidate_artefacts,
                    subject_task,
                )
                subject_task.complete_child("judge", "Reference judgement finished")
                matched = calibration_subject_matches(candidate, judgement)
                subject_task.finish(
                    TaskOutcome.PASSED if matched else TaskOutcome.FAILED,
                    (
                        "Matched expected judgement"
                        if matched
                        else "Did not match expected judgement"
                    ),
                )
                return CalibrationAssessment(
                    candidate=candidate.name,
                    judgement=judgement,
                )
        finally:
            self._instances.clean(instance)

    def _judge_subject(
        self,
        fixture: Fixture,
        subject: JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
        task: TaskRun | None = None,
    ) -> Judgement:
        if subject.name == "candidate":
            description = "Asking the independent judge"
            with self._tasks.task(
                Phase.JUDGE.value,
                TaskKind.PHASE,
                description,
                UnboundedTaskChildren(),
                5,
            ) as judge_task:
                judgement = self._assess(
                    fixture, subject, instance, artefacts, judge_task
                )
                failed = sum(not criterion.passed for criterion in judgement.criteria)
                judge_task.finish(
                    TaskOutcome.PASSED if failed == 0 else TaskOutcome.FAILED,
                    describe_judgement(len(judgement.criteria) - failed, failed),
                )
                return judgement

        return self._assess(fixture, subject, instance, artefacts, task)

    def _assess(
        self,
        fixture: Fixture,
        subject: JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
        task: TaskRun | None = None,
    ) -> Judgement:
        if task is not None:
            task.set_detail("Waiting for an agent slot")
        with self._slots.hold():
            if task is not None:
                task.set_detail("Asking the independent judge")
            judgement = self._judge.assess(fixture, subject, instance, artefacts)
        expected = sorted(criterion.identifier for criterion in fixture.criteria)
        if judgement.identifiers != expected:
            raise JudgementCriteriaError(tuple(expected), tuple(judgement.identifiers))
        return judgement


def task_outcome(summary: RunSummary) -> TaskOutcome:
    """Map a suite result count to its progress outcome."""

    if summary.invalid or summary.stale:
        return TaskOutcome.INVALID
    if summary.failed:
        return TaskOutcome.FAILED
    return TaskOutcome.PASSED


def describe_running_tests(count: int) -> str:
    """Describe a known number of concurrently scheduled tests."""

    noun = "test" if count == 1 else "tests"
    return f"Running {count} {noun}"


def describe_reference_subjects(count: int) -> str:
    """Describe the reference subjects being judged at the same time."""

    noun = "subject" if count == 1 else "subjects"
    return f"Judging {count} reference {noun}"


def describe_captured_work(changed_files: int) -> str:
    """Summarise the repository evidence captured from a candidate run."""

    noun = "file" if changed_files == 1 else "files"
    return f"Captured {changed_files} changed {noun}"


def describe_verification(passed: int, failed: int, flaky: int = 0) -> str:
    """Summarise deterministic check results without hiding failures."""

    quarantined = f", {flaky} flaky" if flaky else ""
    if failed == 0:
        noun = "check" if passed == 1 else "checks"
        return f"{passed} {noun} passed{quarantined}"
    if passed == 0:
        noun = "check" if failed == 1 else "checks"
        return f"{failed} {noun} failed{quarantined}"
    return f"{passed} passed, {failed} failed{quarantined}"


def describe_judgement(passed: int, failed: int) -> str:
    """Summarise the judge verdict represented by a phase outcome."""

    if failed == 0:
        noun = "criterion" if passed == 1 else "criteria"
        return f"{passed} {noun} passed"
    if passed == 0:
        noun = "criterion" if failed == 1 else "criteria"
        return f"{failed} {noun} failed"
    return f"{passed} passed, {failed} failed"


def describe_calibration(passed: int, failed: int) -> str:
    """Summarise whether the judge reproduced all reference expectations."""

    if failed == 0:
        noun = "subject" if passed == 1 else "subjects"
        return f"{passed} reference {noun} matched"
    if passed == 0:
        noun = "subject" if failed == 1 else "subjects"
        return f"{failed} reference {noun} mismatched"
    return f"{passed} matched, {failed} mismatched"


def calibration_subject_matches(
    candidate: CalibrationCandidate,
    judgement: Judgement,
) -> bool:
    """Return whether one opaque judgement matches its declared reference."""

    actual = tuple(
        sorted(
            (criterion.identifier, criterion.passed) for criterion in judgement.criteria
        )
    )
    return actual == candidate.expected_criteria


def fixture_children(calibrate: bool) -> FixedTaskChildren:
    """Allocate fixture progress according to the relative model work involved."""

    allocations = [
        ChildAllocation(Phase.PREPARE.value, 5),
        ChildAllocation(Phase.CANDIDATE.value, 45 if calibrate else 55),
        ChildAllocation(Phase.EVIDENCE.value, 5),
        ChildAllocation(Phase.VERIFY.value, 10),
        ChildAllocation(Phase.JUDGE.value, 15 if calibrate else 25),
    ]
    if calibrate:
        allocations.insert(1, ChildAllocation(Phase.CALIBRATE.value, 20))
    return FixedTaskChildren(tuple(allocations))


def suite_summary(summary: RunSummary) -> str:
    """Describe a completed suite using its complete result counts."""

    return (
        f"{summary.passed} passed, {summary.failed} failed, "
        f"{summary.invalid} invalid, {summary.stale} stale"
    )


def judgement_failures(judgement: Judgement) -> list[str]:
    return [
        f"{criterion.identifier}: {criterion.reason}"
        for criterion in judgement.criteria
        if not criterion.passed
    ]


def calibration_failures(
    fixture: Fixture, assessments: tuple[CalibrationAssessment, ...]
) -> tuple[CriterionExpectationMismatch, ...]:
    by_name = {assessment.candidate: assessment for assessment in assessments}
    failures: list[CriterionExpectationMismatch] = []
    for candidate in fixture.calibration:
        assessment = by_name.get(candidate.name)
        if assessment is None:
            failures.append(
                CriterionExpectationMismatch(
                    candidate.name,
                    candidate.expected_criteria,
                    (),
                )
            )
            continue
        actual = tuple(
            sorted(
                (criterion.identifier, criterion.passed)
                for criterion in assessment.judgement.criteria
            )
        )
        if actual != candidate.expected_criteria:
            failures.append(
                CriterionExpectationMismatch(
                    candidate.name,
                    candidate.expected_criteria,
                    actual,
                )
            )
    return tuple(failures)


def verification_gate_failures(
    verification: tuple[VerificationResult, ...],
) -> tuple[VerificationFailure, ...]:
    """Describe deterministic gate failures without treating diagnostics as gates."""

    return tuple(
        VerificationFailure(
            result.name,
            result.expected_return_code,
            result.return_code,
        )
        for result in verification
        if result.kind is VerificationKind.GATE and not result.passed
    )


def load_fixtures(manifest: Path) -> tuple[Fixture, ...]:
    """Load the Nix-assembled fixture manifest into domain values."""

    try:
        values = msgspec.json.decode(
            manifest.read_bytes(), type=tuple[FixtureInput, ...]
        )
        return tuple(Fixture.from_input(value) for value in values)
    except (
        OSError,
        ValueError,
        msgspec.DecodeError,
        msgspec.ValidationError,
    ) as error:
        raise FixtureManifestFormatError(manifest, error) from error


def select_fixtures(
    fixtures: tuple[Fixture, ...], selection: Selection
) -> tuple[Fixture, ...]:
    """Select fixtures by exact names or intersected category and tag filters."""

    if selection.names:
        by_name = {fixture.name: fixture for fixture in fixtures}
        unknown = [name for name in selection.names if name not in by_name]
        if unknown:
            name, *_ = unknown
            raise UnknownFixtureSelectionError(name)
        return tuple(by_name[name] for name in selection.names)

    selected = fixtures
    if selection.categories:
        selected = tuple(
            item for item in selected if item.category in selection.categories
        )
    if selection.tags:
        selected = tuple(
            item for item in selected if any(tag in item.tags for tag in selection.tags)
        )
    if not selected:
        raise EmptyFixtureSelectionError
    return selected


def prepare_output(
    output: Path,
    run_metadata: Path,
    prompt_context: Path,
    *,
    root: Path | None = None,
) -> None:
    """Create or resume a marked result directory with matching snapshots."""

    resolved = output.resolve()
    protected_paths = {
        Path(resolved.anchor),
        Path.cwd().resolve(),
        Path.home().resolve(),
    }
    if resolved in protected_paths:
        raise ProtectedOutputPathError(resolved)
    exists = (
        directory_exists(root.resolve(), resolved)
        if root is not None
        else resolved.exists()
    )
    if exists:
        if not resolved.is_dir():
            raise OutputPathNotDirectoryError(resolved)
        if not (resolved / OUTPUT_MARKER).is_file():
            if root is None:
                raise OutputPathUnmarkedError(resolved)

            owner = root.resolve()
            identity = directory_identity(owner, resolved)
            remove_identified_directory(owner, resolved, identity)
            exists = False
    if exists:
        validate_output_snapshots(resolved, run_metadata, prompt_context)
        return
    if root is None:
        resolved.mkdir(parents=True)
    else:
        ensure_directory(root.resolve(), resolved)
    metadata_snapshot = resolved / "run-metadata.json"
    prompt_snapshot = resolved / "prompt-context.json"
    try:
        contents = run_metadata.read_bytes()
        if root is None:
            metadata_snapshot.write_bytes(contents)
        else:
            atomic_write(root.resolve(), metadata_snapshot, contents)
    except OSError as error:
        raise RunMetadataSnapshotError(
            run_metadata, metadata_snapshot, error
        ) from error
    try:
        contents = prompt_context.read_bytes()
        if root is None:
            prompt_snapshot.write_bytes(contents)
        else:
            atomic_write(root.resolve(), prompt_snapshot, contents)
    except OSError as error:
        raise PromptContextSnapshotError(
            prompt_context, prompt_snapshot, error
        ) from error
    marker = (
        json.dumps(
            {
                "promptContext": prompt_snapshot.name,
                "runMetadata": metadata_snapshot.name,
            },
            sort_keys=True,
        )
        + "\n"
    )
    if root is None:
        (resolved / OUTPUT_MARKER).write_text(marker)
    else:
        atomic_write(root.resolve(), resolved / OUTPUT_MARKER, marker.encode())


def validate_output_snapshots(
    output: Path,
    run_metadata: Path,
    prompt_context: Path,
) -> None:
    """Ensure an existing result directory belongs to the same prompt run."""

    try:
        matches = (
            output / "run-metadata.json"
        ).read_bytes() == run_metadata.read_bytes() and (
            output / "prompt-context.json"
        ).read_bytes() == prompt_context.read_bytes()
    except OSError as error:
        raise OutputSnapshotMismatchError(output) from error
    if not matches:
        raise OutputSnapshotMismatchError(output)
