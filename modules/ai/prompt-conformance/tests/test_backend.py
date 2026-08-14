import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from pathlib import Path
from threading import Barrier, Lock

import msgspec
import pytest

from claude_prompt_conformance import models
from claude_prompt_conformance.agents.candidate import CandidateProcessError
from claude_prompt_conformance.agents.codex import (
    CodexAgentExecutionError,
    CodexFeatureIsolationError,
    JudgeProcessError,
)
from claude_prompt_conformance.agents.judge import JudgementEvidenceUnreadError
from claude_prompt_conformance.backend import (
    ConformanceSuite,
    FixtureRun,
    RunRequest,
    RunSummary,
    Selection,
    fixture_children,
    prepare_output,
    select_fixtures,
)
from claude_prompt_conformance.checkpoints import (
    FixtureCheckpointMismatchError,
    FixtureEvidenceMismatchError,
    JsonFixtureResultStore,
    RunMetadataDecodeError,
    StoredCalibration,
    StoredTestResult,
    calibration_inventory,
    encode_path,
    evidence_inventory,
    fixture_contract,
    judge_identity,
)
from claude_prompt_conformance.errors import ConformanceError
from claude_prompt_conformance.models import (
    CalibrationAssessment,
    CandidateResult,
    Fixture,
    FixtureCheckpoint,
    InstancePaths,
    JudgementSubject,
    PassingJudgementInconsistentError,
    SuiteFinished,
)
from claude_prompt_conformance.models import (
    TestStatus as Status,
)
from claude_prompt_conformance.ports import (
    ActivityReporter,
    CandidateAgent,
    FixtureResultStore,
    Judge,
    ProcessController,
    Verifier,
)
from claude_prompt_conformance.process import (
    MissingProcessStatusError,
    ProcessStartError,
)
from claude_prompt_conformance.progress import TaskKind as ProgressTaskKind
from claude_prompt_conformance.progress import TaskOutcome, TaskRun, TaskScopes
from claude_prompt_conformance.run_store import OutputPathUnmarkedError
from claude_prompt_conformance.task_children import ChildAllocation, FixedTaskChildren
from claude_prompt_conformance.verification import CommandVerifier

from .helpers import (
    FakeCandidate,
    FakeInspector,
    FakeInstances,
    FakeJudge,
    FakeOverlay,
    FakePreparer,
    FakeProcesses,
    FakeRepositories,
    FakeVerifier,
    RecordingEvents,
    RecordingRoots,
    RecordingSlots,
    TaskOutline,
    candidate_result,
    judgement,
    make_fixture,
    task_outlines,
    verification_results,
    workspace_evidence,
)

type TaskTerminalTree = tuple[
    TaskOutcome | None,
    str,
    tuple["TaskTerminalTree", ...],
]


class ConcurrentCandidate(FakeCandidate):
    def __init__(self, participants: int) -> None:
        self._barrier = Barrier(participants)

    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        self._barrier.wait()
        return super().run(fixture, instance, artefacts, activity)


class ConcurrentCalibrationJudge(FakeJudge):
    """Require every reference subject of one fixture to be judged together."""

    def __init__(self, participants: int) -> None:
        self._barrier = Barrier(participants, timeout=30)

    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        if subject.name != "candidate":
            self._barrier.wait()
        return super().assess(fixture, subject, instance, artefacts)


class InstanceRecordingJudge(FakeJudge):
    """Record the judge state directory each assessment writes into."""

    def __init__(self) -> None:
        self.states: list[tuple[str, Path]] = []
        self._lock = Lock()

    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        with self._lock:
            self.states.append((subject.name, instance.judge_state))
        return super().assess(fixture, subject, instance, artefacts)


@dataclass
class ScriptedRunner:
    """Answer each attempt at a verification command with a scripted status."""

    return_codes: list[int]
    attempts: int = 0

    def run(self, invocation: models.ProcessInvocation) -> models.ProcessResult:
        invocation.stdout.write_text(f"attempt {self.attempts + 1}\n")
        invocation.stderr.write_text("")
        return_code = self.return_codes[self.attempts]
        self.attempts += 1
        return models.ProcessResult(return_code)


class QuarantinedVerifier(FakeVerifier):
    """Report a gate which only passed when it was retried."""

    def verify(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> tuple[models.VerificationResult, ...]:
        return tuple(
            replace(result, flaky=True)
            for result in super().verify(fixture, instance, artefacts)
        )


class InterruptingCandidate:
    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        raise KeyboardInterrupt


class RejectingCandidateJudge(FakeJudge):
    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        if subject.name == "candidate":
            return judgement(False, subject.evidence.head_revision)
        return super().assess(fixture, subject, instance, artefacts)


class RecordingCancellation:
    def __init__(self, marker: Path) -> None:
        self._marker = marker

    def cancel(self) -> None:
        self._marker.write_text("cancelled\n")


class RaisingJudge:
    def __init__(self, error: ConformanceError) -> None:
        self._error = error

    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        raise self._error


class RaisingCandidate:
    def __init__(self, error: ConformanceError) -> None:
        self._error = error

    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        raise self._error


class UnexpectedCandidate:
    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        raise AssertionError("a completed fixture must not run the candidate again")


class UnexpectedJudge:
    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        raise AssertionError("a completed fixture must not run the judge again")


class CountingJudge(FakeJudge):
    """Record every subject assessed, so repeated model work is visible."""

    def __init__(self) -> None:
        self._lock = Lock()
        self._subjects: list[str] = []

    @property
    def subjects(self) -> tuple[str, ...]:
        """Return the assessed subjects in a concurrency-independent order."""

        with self._lock:
            return tuple(sorted(self._subjects))

    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        with self._lock:
            self._subjects.append(subject.name)
        return super().assess(fixture, subject, instance, artefacts)


class FailingCandidateJudge(FakeJudge):
    def assess(
        self,
        fixture: Fixture,
        subject: models.JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> models.Judgement:
        if subject.name == "candidate":
            stderr = artefacts / "judge.stderr"
            stderr.write_text("judge unavailable\n")
            raise JudgeProcessError(1, stderr)
        return super().assess(fixture, subject, instance, artefacts)


@dataclass
class RecordingResultStore:
    """Record the confinement root every retained-result operation receives."""

    delegate: JsonFixtureResultStore = field(default_factory=JsonFixtureResultStore)
    roots: list[tuple[str, Path]] = field(default_factory=list)

    def load(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        *,
        calibrate: bool,
    ) -> FixtureCheckpoint | models.TestResult | None:
        self.roots.append(("load", root))
        return self.delegate.load(root, fixture, artefacts, calibrate=calibrate)

    def load_calibration(
        self,
        root: Path,
        fixture: Fixture,
        *,
        judge: str,
    ) -> models.RetainedCalibration | None:
        self.roots.append(("load_calibration", root))
        return self.delegate.load_calibration(root, fixture, judge=judge)

    def reset(
        self,
        root: Path,
        artefacts: Path,
        *,
        retain_calibration: bool = False,
    ) -> None:
        self.roots.append(("reset", root))
        self.delegate.reset(root, artefacts, retain_calibration=retain_calibration)

    def save_calibration(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        calibration: tuple[CalibrationAssessment, ...],
        *,
        judge: str,
    ) -> None:
        self.roots.append(("save_calibration", root))
        self.delegate.save_calibration(
            root,
            fixture,
            artefacts,
            calibration,
            judge=judge,
        )

    def save_checkpoint(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        checkpoint: FixtureCheckpoint,
    ) -> None:
        self.roots.append(("save_checkpoint", root))
        self.delegate.save_checkpoint(root, fixture, artefacts, checkpoint)

    def save_result(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        result: models.TestResult,
    ) -> None:
        self.roots.append(("save_result", root))
        self.delegate.save_result(root, fixture, artefacts, result)


@dataclass
class SynchronisedCalibrationStore(RecordingResultStore):
    """Hold every arm at the calibration lookup until they have all arrived."""

    barrier: Barrier = field(default_factory=lambda: Barrier(2, timeout=30))

    def load_calibration(
        self,
        root: Path,
        fixture: Fixture,
        *,
        judge: str,
    ) -> models.RetainedCalibration | None:
        retained = super().load_calibration(root, fixture, judge=judge)
        self.barrier.wait()
        return retained


def suite(
    metadata: Path,
    events: RecordingEvents,
    *,
    candidate: CandidateAgent | None = None,
    judge: Judge | None = None,
    processes: ProcessController | None = None,
    tasks: TaskScopes | None = None,
    results: FixtureResultStore | None = None,
    slots: RecordingSlots | None = None,
    verifier: Verifier | None = None,
    metadata_document: str = '{"run":"test"}\n',
) -> ConformanceSuite:
    metadata.write_text(metadata_document)
    prompt_context = metadata.with_name("prompt-context-source.json")
    prompt_context.write_text('{"prompt":"test"}\n')
    return ConformanceSuite(
        FakeInstances(),
        FakeRepositories(),
        FakeOverlay(),
        FakePreparer(),
        candidate or FakeCandidate(),
        FakeInspector(),
        verifier or FakeVerifier(),
        judge or FakeJudge(),
        events,
        tasks or TaskScopes(RecordingRoots()),
        processes or FakeProcesses(),
        slots or RecordingSlots(),
        results or JsonFixtureResultStore(),
        metadata,
        prompt_context,
    )


def test_suite_orchestrates_capabilities_and_calibrates_the_judge(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures", comparison_revision="comparison")
    events = RecordingEvents()
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    roots = RecordingRoots()

    summary = suite(metadata, events, tasks=TaskScopes(roots)).run(
        RunRequest(output, (fixture,))
    )

    artefacts = output / fixture.name
    result = models.TestResult(
        candidate=candidate_result(artefacts),
        evidence=workspace_evidence("comparison", "base", artefacts),
        verification=verification_results("base", artefacts),
        judgement=judgement(True, "base"),
        calibration=(
            CalibrationAssessment("known-good", judgement(True, "good")),
            CalibrationAssessment("unchanged-base", judgement(False, "base")),
        ),
    )
    checkpoint = FixtureCheckpoint(
        candidate=result.candidate,
        subject=JudgementSubject(
            name="candidate",
            workspace=result.evidence.workspace,
            response=result.candidate.response,
            trace=result.candidate.trace,
            evidence=result.evidence,
            verification=result.verification,
        ),
        calibration=result.calibration,
        contract=fixture_contract(fixture),
    )
    assert (summary, events.events, task_outlines(roots)) == (
        RunSummary(
            passed=1,
            failed=0,
            invalid=0,
            stale=0,
            results=(
                FixtureRun(
                    fixture,
                    Status.PASSED,
                    artefacts,
                    (),
                    result,
                    None,
                ),
            ),
        ),
        [
            models.TestFinished(
                fixture_name=fixture.name,
                status=Status.PASSED,
                summary="assessment",
                failures=(),
                result=result,
            ),
            SuiteFinished(1, 0, 0, 0, output, metadata),
        ],
        (
            TaskOutline(
                path=("conformance",),
                kind=ProgressTaskKind.SUITE,
                completed=1,
                total=1,
                outcome=TaskOutcome.PASSED,
                children=(
                    TaskOutline(
                        path=("conformance", fixture.name),
                        kind=ProgressTaskKind.FIXTURE,
                        completed=6,
                        total=6,
                        outcome=TaskOutcome.PASSED,
                        children=(
                            TaskOutline(
                                path=("conformance", fixture.name, "prepare"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "calibrate"),
                                kind=ProgressTaskKind.PHASE,
                                completed=2,
                                total=2,
                                outcome=TaskOutcome.PASSED,
                                children=tuple(
                                    TaskOutline(
                                        path=(
                                            "conformance",
                                            fixture.name,
                                            "calibrate",
                                            f"subject-{index:02}",
                                        ),
                                        kind=ProgressTaskKind.PHASE,
                                        completed=4,
                                        total=4,
                                        outcome=TaskOutcome.PASSED,
                                        children=(),
                                    )
                                    for index in (1, 2)
                                ),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "candidate"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "evidence"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "verify"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.PASSED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "judge"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.PASSED,
                                children=(),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )
    assert {
        str(path.relative_to(output)): path.read_text()
        for path in output.rglob("*")
        if path.is_file()
    } == {
        ".claude-prompt-conformance": (
            '{"promptContext": "prompt-context.json", '
            '"runMetadata": "run-metadata.json"}\n'
        ),
        "prompt-context.json": '{"prompt":"test"}\n',
        "run-metadata.json": '{"run":"test"}\n',
        "example/calibration/subject-01/check.stderr": "",
        "example/calibration/subject-01/check.stdout": "verified good\n",
        "example/calibration/subject-01/commits.txt": "commit good\n",
        "example/calibration/subject-01/diff.patch": "diff for good\n",
        "example/calibration/subject-01/preparation.txt": "example\n",
        "example/calibration/subject-01/actions.json": "[]",
        "example/calibration/subject-01/workspace-snapshot/file": (
            "contents at good\n"
        ),
        "example/calibration/subject-02/check.stderr": "",
        "example/calibration/subject-02/check.stdout": "verified base\n",
        "example/calibration/subject-02/commits.txt": "commit base\n",
        "example/calibration/subject-02/diff.patch": "diff for base\n",
        "example/calibration/subject-02/preparation.txt": "example\n",
        "example/calibration/subject-02/actions.json": "[]",
        "example/calibration/subject-02/workspace-snapshot/file": (
            "contents at base\n"
        ),
        "example/check.stderr": "",
        "example/check.stdout": "verified base\n",
        "example/commits.txt": "commit base\n",
        "example/diff.patch": "diff for base\n",
        ".claude-prompt-conformance-state/calibration/example.json": msgspec.json.encode(
            StoredCalibration(
                result.calibration,
                fixture_contract(fixture),
                judge_identity(metadata),
                calibration_inventory(artefacts),
                fixture.name,
            )
        ).decode(),
        "example/.claude-prompt-conformance-state/checkpoint.json": msgspec.json.encode(
            replace(checkpoint, evidence=evidence_inventory(checkpoint, artefacts)),
            enc_hook=lambda value: encode_path(artefacts, value),
        ).decode(),
        "example/.claude-prompt-conformance-state/result.json": msgspec.json.encode(
            StoredTestResult(
                result,
                fixture_contract(fixture),
                evidence_inventory(checkpoint, artefacts),
            ),
            enc_hook=lambda value: encode_path(artefacts, value),
        ).decode(),
        "example/preparation.txt": "example\n",
        "example/response.md": "candidate response",
        "example/trace.jsonl": "{}\n",
        "example/transcript.jsonl": "{}\n",
        "example/workspace-snapshot/file": "contents at base\n",
    }


def test_failed_judgement_is_visible_beneath_the_failed_fixture(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    roots = RecordingRoots()

    summary = suite(
        tmp_path / "run.json",
        RecordingEvents(),
        judge=RejectingCandidateJudge(),
        tasks=TaskScopes(roots),
    ).run(RunRequest(tmp_path / "results", (fixture,)))

    assert (
        summary.failed,
        tuple(task_terminal_tree(root) for root in roots.roots),
    ) == (
        1,
        (
            (
                TaskOutcome.FAILED,
                "0 passed, 1 failed, 0 invalid, 0 stale",
                (
                    (
                        TaskOutcome.FAILED,
                        "assessment",
                        (
                            (TaskOutcome.COMPLETED, "Checkout prepared", ()),
                            (
                                TaskOutcome.PASSED,
                                "2 reference subjects matched",
                                (
                                    (
                                        TaskOutcome.PASSED,
                                        "Matched expected judgement",
                                        (),
                                    ),
                                    (
                                        TaskOutcome.PASSED,
                                        "Matched expected judgement",
                                        (),
                                    ),
                                ),
                            ),
                            (
                                TaskOutcome.COMPLETED,
                                "Candidate response received",
                                (),
                            ),
                            (
                                TaskOutcome.COMPLETED,
                                "Captured 1 changed file",
                                (),
                            ),
                            (TaskOutcome.PASSED, "1 check passed", ()),
                            (TaskOutcome.FAILED, "1 criterion failed", ()),
                        ),
                    ),
                ),
            ),
        ),
    )


def task_terminal_tree(
    task: TaskRun,
) -> TaskTerminalTree:
    """Project terminal semantics without coupling to timing or revisions."""

    snapshot = task.snapshot()
    return (
        snapshot.outcome,
        snapshot.detail,
        tuple(task_terminal_tree(child) for child in task.children),
    )


def test_fixture_progress_allocates_every_phase_by_relative_cost() -> None:
    assert tuple(fixture_children(calibrate) for calibrate in (True, False)) == (
        FixedTaskChildren(
            (
                ChildAllocation("prepare", 5),
                ChildAllocation("calibrate", 20),
                ChildAllocation("candidate", 45),
                ChildAllocation("evidence", 5),
                ChildAllocation("verify", 10),
                ChildAllocation("judge", 15),
            )
        ),
        FixedTaskChildren(
            (
                ChildAllocation("prepare", 5),
                ChildAllocation("candidate", 55),
                ChildAllocation("evidence", 5),
                ChildAllocation("verify", 10),
                ChildAllocation("judge", 25),
            )
        ),
    )


def test_suite_runs_independent_fixtures_concurrently(tmp_path: Path) -> None:
    fixtures = (
        make_fixture(tmp_path / "fixtures", name="one"),
        make_fixture(tmp_path / "fixtures", name="two"),
    )
    output = tmp_path / "results"

    summary = suite(
        tmp_path / "run.json",
        RecordingEvents(),
        candidate=ConcurrentCandidate(len(fixtures)),
    ).run(RunRequest(output, fixtures, calibrate=False))

    assert (
        summary.passed,
        summary.failed,
        summary.invalid,
        tuple((run.fixture.name, run.status) for run in summary.results),
        tuple(
            (fixture.name, (output / fixture.name / "response.md").read_text())
            for fixture in fixtures
        ),
    ) == (
        2,
        0,
        0,
        (("one", Status.PASSED), ("two", Status.PASSED)),
        (("one", "candidate response"), ("two", "candidate response")),
    )


def test_agent_phases_hold_a_run_slot_and_cheap_phases_do_not(
    tmp_path: Path,
) -> None:
    fixtures = tuple(
        make_fixture(tmp_path / "fixtures", name=name)
        for name in ("one", "two", "three", "four")
    )
    slots = RecordingSlots(capacity=2)

    summary = suite(
        tmp_path / "run.json",
        RecordingEvents(),
        candidate=ConcurrentCandidate(2),
        slots=slots,
    ).run(RunRequest(tmp_path / "results", fixtures, calibrate=False))

    assert (summary.passed, slots.peak, slots.held, slots.active) == (4, 2, 8, 0)


def test_calibration_subjects_are_judged_concurrently(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    slots = RecordingSlots()

    summary = suite(
        tmp_path / "run.json",
        RecordingEvents(),
        judge=ConcurrentCalibrationJudge(len(fixture.calibration)),
        slots=slots,
    ).run(RunRequest(tmp_path / "results", (fixture,)))

    assert (summary.passed, slots.peak, slots.held, slots.active) == (1, 2, 4, 0)


def test_concurrent_calibration_subjects_never_share_judge_state(
    tmp_path: Path,
) -> None:
    """Judge sessions rewrite their instance configuration, so sharing races."""

    fixture = make_fixture(tmp_path / "fixtures")
    judge = InstanceRecordingJudge()

    summary = suite(
        tmp_path / "run.json",
        RecordingEvents(),
        judge=judge,
    ).run(RunRequest(tmp_path / "results", (fixture,)))

    states = tuple(state for _, state in judge.states)
    assert (summary.passed, len(states), len(set(states))) == (1, 3, 3)


@pytest.mark.parametrize(
    ("kind", "return_codes", "expected"),
    [
        pytest.param(
            models.VerificationKind.GATE,
            (0,),
            (True, False, "0", ("verification-0.stdout",)),
            id="gate-passes",
        ),
        pytest.param(
            models.VerificationKind.GATE,
            (1, 0),
            (
                True,
                True,
                "0.retry",
                ("verification-0.retry.stdout", "verification-0.stdout"),
            ),
            id="gate-passes-when-retried",
        ),
        pytest.param(
            models.VerificationKind.GATE,
            (1, 1),
            (
                False,
                False,
                "0.retry",
                ("verification-0.retry.stdout", "verification-0.stdout"),
            ),
            id="gate-fails-twice",
        ),
        pytest.param(
            models.VerificationKind.DIAGNOSTIC,
            (1,),
            (False, False, "0", ("verification-0.stdout",)),
            id="diagnostic-is-not-retried",
        ),
    ],
)
def test_a_failed_gate_is_retried_once_before_it_counts(
    tmp_path: Path,
    kind: models.VerificationKind,
    return_codes: tuple[int, ...],
    expected: tuple[bool, bool, str, tuple[str, ...]],
) -> None:
    (check,) = make_fixture(tmp_path / "fixtures").verification
    fixture = replace(
        make_fixture(tmp_path / "fixtures", name="retried"),
        verification=(replace(check, kind=kind),),
    )
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    instance = FakeInstances().create("candidate", artefacts)
    runner = ScriptedRunner(list(return_codes))

    (result,) = CommandVerifier(runner).verify(fixture, instance, artefacts)

    assert (
        result.passed,
        result.flaky,
        result.stdout.name.removeprefix("verification-").removesuffix(".stdout"),
        tuple(sorted(path.name for path in artefacts.glob("verification-*.stdout"))),
        runner.attempts,
    ) == (*expected, len(return_codes))


def test_a_quarantined_gate_does_not_fail_its_fixture(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    events = RecordingEvents()

    summary = suite(
        tmp_path / "run.json",
        events,
        verifier=QuarantinedVerifier(),
    ).run(RunRequest(tmp_path / "results", (fixture,), calibrate=False))

    (run,) = summary.results
    assert run.result is not None
    assert (
        summary.passed,
        run.failures,
        tuple(check.flaky for check in run.result.verification),
    ) == (1, (), (True,))


def test_suite_reuses_a_complete_result_when_the_run_store_already_exists(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    first_events = RecordingEvents()
    first = suite(metadata, first_events).run(RunRequest(output, (fixture,)))
    resumed_events = RecordingEvents()
    roots = RecordingRoots()

    resumed = suite(
        metadata,
        resumed_events,
        candidate=UnexpectedCandidate(),
        judge=UnexpectedJudge(),
        tasks=TaskScopes(roots),
    ).run(RunRequest(output, (fixture,)))

    assert (resumed, resumed_events.events, task_outlines(roots)) == (
        first,
        first_events.events,
        (
            TaskOutline(
                path=("conformance",),
                kind=ProgressTaskKind.SUITE,
                completed=1,
                total=1,
                outcome=TaskOutcome.PASSED,
                children=(
                    TaskOutline(
                        path=("conformance", fixture.name),
                        kind=ProgressTaskKind.FIXTURE,
                        completed=6,
                        total=6,
                        outcome=TaskOutcome.PASSED,
                        children=(),
                    ),
                ),
            ),
        ),
    )


def reference_calibration() -> tuple[CalibrationAssessment, ...]:
    """Describe the reference judgements every arm of one run store shares."""

    return (
        CalibrationAssessment("known-good", judgement(True, "good")),
        CalibrationAssessment("unchanged-base", judgement(False, "base")),
    )


def draft_metadata(draft: str) -> str:
    """Describe one improvement arm, which differs only in its own prompt."""

    return json.dumps(
        {
            "codex": {"judge": {"model": "judge-model", "effort": "high"}},
            "prompt": {"AGENTS.md": draft},
        }
    )


def arm_request(store_root: Path, fixture: Fixture, sample: int) -> RunRequest:
    """Evaluate one fixture in one sample of a shared improvement run store."""

    return RunRequest(
        store_root / f"sample-{sample:02}",
        (fixture,),
        store_root=store_root,
    )


def test_a_second_arm_reuses_the_calibration_the_first_arm_paid_for(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    store_root = tmp_path / "store"
    store_root.mkdir()
    first_judge = CountingJudge()
    second_judge = CountingJudge()

    first = suite(
        tmp_path / "first-run.json",
        RecordingEvents(),
        judge=first_judge,
        metadata_document=draft_metadata("first draft"),
    ).run(arm_request(store_root, fixture, 1))
    second = suite(
        tmp_path / "second-run.json",
        RecordingEvents(),
        judge=second_judge,
        metadata_document=draft_metadata("second draft"),
    ).run(arm_request(store_root, fixture, 2))
    ((first_run,), (second_run,)) = (first.results, second.results)
    assert first_run.result is not None
    assert second_run.result is not None

    assert (
        (first.passed, second.passed),
        first_judge.subjects,
        second_judge.subjects,
        (first_run.result.calibration, second_run.result.calibration),
        (store_root / "sample-01" / fixture.name / "calibration").is_dir(),
        (store_root / "sample-02" / fixture.name / "calibration").exists(),
        tuple(
            sorted(
                path.name
                for path in (
                    store_root / ".claude-prompt-conformance-state" / "calibration"
                ).iterdir()
            )
        ),
    ) == (
        (1, 1),
        ("candidate", "subject-01", "subject-02"),
        ("candidate",),
        (reference_calibration(), reference_calibration()),
        True,
        False,
        (f"{fixture.name}.json",),
    )


def test_arms_calibrating_one_fixture_at_the_same_time_reach_one_answer(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    store_root = tmp_path / "store"
    store_root.mkdir()
    counting = CountingJudge()
    results = SynchronisedCalibrationStore()
    arms = tuple(
        suite(
            tmp_path / f"draft-{sample}-run.json",
            RecordingEvents(),
            judge=counting,
            results=results,
            metadata_document=draft_metadata(f"draft {sample}"),
        )
        for sample in (1, 2)
    )

    with ThreadPoolExecutor(max_workers=len(arms)) as executor:
        futures = [
            executor.submit(arm.run, arm_request(store_root, fixture, sample))
            for sample, arm in enumerate(arms, start=1)
        ]
        summaries = tuple(future.result() for future in futures)

    published = JsonFixtureResultStore().load_calibration(
        store_root,
        fixture,
        judge=judge_identity(tmp_path / "draft-1-run.json"),
    )
    assert published is not None

    assert (
        tuple(summary.passed for summary in summaries),
        counting.subjects,
        tuple(
            run.result.calibration
            for summary in summaries
            for run in summary.results
            if run.result is not None
        ),
        published.assessments,
        published.artefacts.parent.parent,
    ) == (
        (1, 1),
        (
            "candidate",
            "candidate",
            "subject-01",
            "subject-01",
            "subject-02",
            "subject-02",
        ),
        (reference_calibration(), reference_calibration()),
        reference_calibration(),
        store_root.resolve(),
    )


@pytest.mark.parametrize(
    ("first", "second", "shared"),
    [
        pytest.param(
            {"prompt": {"AGENTS.md": "first"}},
            {"prompt": {"AGENTS.md": "second"}},
            True,
            id="candidate-prompt",
        ),
        pytest.param(
            {"outputStyles": {"plain": "first"}},
            {"outputStyles": {"plain": "second"}},
            True,
            id="candidate-output-styles",
        ),
        pytest.param(
            {"defaultOutputStyle": "plain"},
            {"defaultOutputStyle": "technical"},
            True,
            id="candidate-default-output-style",
        ),
        pytest.param(
            {"codex": {"judge": {"effort": "high"}}},
            {"codex": {"judge": {"effort": "low"}}},
            False,
            id="judge-effort",
        ),
        pytest.param(
            {"claude": {"model": "first"}},
            {"claude": {"model": "second"}},
            False,
            id="candidate-client",
        ),
    ],
)
def test_judge_identity_binds_every_run_input_but_the_candidate_prompt(
    tmp_path: Path,
    first: dict[str, object],
    second: dict[str, object],
    shared: bool,
) -> None:
    documents = tuple(tmp_path / f"run-{index}.json" for index in (1, 2))
    for path, members in zip(documents, (first, second), strict=True):
        path.write_text(json.dumps({"codex": {"version": "1.0"}} | members))

    assert (judge_identity(documents[0]) == judge_identity(documents[1])) == shared


def test_judge_identity_rejects_run_metadata_which_is_not_a_document(
    tmp_path: Path,
) -> None:
    metadata = tmp_path / "run.json"
    metadata.write_text("not a document\n")

    with pytest.raises(RunMetadataDecodeError) as raised:
        judge_identity(metadata)

    assert raised.value.source == metadata


def test_suite_reuses_calibration_after_the_candidate_phase_failed(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    artefacts = output / fixture.name
    request = RunRequest(output, (fixture,))
    counting = CountingJudge()
    failed = suite(
        metadata,
        RecordingEvents(),
        judge=counting,
        candidate=RaisingCandidate(
            CandidateProcessError(
                1,
                artefacts / "transcript.jsonl",
                artefacts / "candidate.stderr",
            )
        ),
    ).run(request)
    calibration = output / ".claude-prompt-conformance-state/calibration/example.json"
    retained = calibration.read_bytes()
    stale = artefacts / "abandoned-attempt"
    stale.write_text("abandoned\n")
    roots = RecordingRoots()

    resumed = suite(
        metadata, RecordingEvents(), judge=counting, tasks=TaskScopes(roots)
    ).run(request)
    (resumed_run,) = resumed.results
    assert resumed_run.result is not None

    assert (
        (failed.invalid, resumed.passed),
        counting.subjects,
        resumed_run.result.calibration,
        calibration.read_bytes(),
        stale.exists(),
        task_outlines(roots),
    ) == (
        (1, 1),
        ("candidate", "subject-01", "subject-02"),
        (
            CalibrationAssessment("known-good", judgement(True, "good")),
            CalibrationAssessment("unchanged-base", judgement(False, "base")),
        ),
        retained,
        False,
        (
            TaskOutline(
                path=("conformance",),
                kind=ProgressTaskKind.SUITE,
                completed=1,
                total=1,
                outcome=TaskOutcome.PASSED,
                children=(
                    TaskOutline(
                        path=("conformance", fixture.name),
                        kind=ProgressTaskKind.FIXTURE,
                        completed=6,
                        total=6,
                        outcome=TaskOutcome.PASSED,
                        children=(
                            TaskOutline(
                                path=("conformance", fixture.name, "prepare"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "candidate"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "evidence"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.COMPLETED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "verify"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.PASSED,
                                children=(),
                            ),
                            TaskOutline(
                                path=("conformance", fixture.name, "judge"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.PASSED,
                                children=(),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )


def test_suite_calibrates_again_when_the_judge_configuration_changed(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    artefacts = output / fixture.name
    request = RunRequest(output, (fixture,))
    counting = CountingJudge()
    suite(
        metadata,
        RecordingEvents(),
        judge=counting,
        candidate=RaisingCandidate(
            CandidateProcessError(
                1,
                artefacts / "transcript.jsonl",
                artefacts / "candidate.stderr",
            )
        ),
    ).run(request)
    calibration = output / ".claude-prompt-conformance-state/calibration/example.json"
    stored = msgspec.json.decode(calibration.read_bytes())
    calibration.write_bytes(msgspec.json.encode(stored | {"judge": "another-judge"}))

    resumed = suite(metadata, RecordingEvents(), judge=counting).run(request)
    (resumed_run,) = resumed.results

    assert (
        (resumed.passed, resumed.failed, resumed.invalid, resumed.stale),
        resumed_run.status,
        type(resumed_run.error),
        counting.subjects,
    ) == (
        (0, 0, 0, 1),
        Status.STALE,
        FixtureCheckpointMismatchError,
        ("subject-01", "subject-02"),
    )


@pytest.mark.parametrize("replacement", [None, "changed after calibration\n"])
def test_suite_rejects_missing_or_changed_calibration_evidence(
    tmp_path: Path,
    replacement: str | None,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    artefacts = output / fixture.name
    request = RunRequest(output, (fixture,))
    suite(
        metadata,
        RecordingEvents(),
        candidate=RaisingCandidate(
            CandidateProcessError(
                1,
                artefacts / "transcript.jsonl",
                artefacts / "candidate.stderr",
            )
        ),
    ).run(request)
    evidence = artefacts / "calibration/subject-01/diff.patch"
    if replacement is None:
        evidence.unlink()
    else:
        evidence.write_text(replacement)

    resumed = suite(metadata, RecordingEvents(), judge=UnexpectedJudge()).run(request)
    (result,) = resumed.results

    assert (
        (resumed.passed, resumed.failed, resumed.invalid, resumed.stale),
        result.status,
        type(result.error),
        result.result,
    ) == (
        (0, 0, 0, 1),
        Status.STALE,
        FixtureEvidenceMismatchError,
        None,
    )


def test_suite_does_not_reuse_a_result_for_a_changed_fixture_contract(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    suite(metadata, RecordingEvents()).run(RunRequest(output, (fixture,)))
    fixture.task.write_text("A materially different task.\n")

    resumed = suite(
        metadata,
        RecordingEvents(),
        candidate=UnexpectedCandidate(),
        judge=UnexpectedJudge(),
    ).run(RunRequest(output, (fixture,)))
    (result,) = resumed.results

    assert (
        resumed.passed,
        resumed.failed,
        resumed.invalid,
        resumed.stale,
        result.status,
        type(result.error),
        result.result,
    ) == (
        0,
        0,
        0,
        1,
        Status.STALE,
        FixtureCheckpointMismatchError,
        None,
    )


@pytest.mark.parametrize("replacement", [None, "changed after judgement\n"])
def test_suite_rejects_missing_or_changed_evidence_from_a_complete_result(
    tmp_path: Path,
    replacement: str | None,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    suite(metadata, RecordingEvents()).run(RunRequest(output, (fixture,)))
    evidence = output / fixture.name / "workspace-snapshot/file"
    if replacement is None:
        evidence.unlink()
    else:
        evidence.write_text(replacement)

    resumed = suite(
        metadata,
        RecordingEvents(),
        candidate=UnexpectedCandidate(),
        judge=UnexpectedJudge(),
    ).run(RunRequest(output, (fixture,)))
    (result,) = resumed.results

    assert (
        resumed.passed,
        resumed.failed,
        resumed.invalid,
        resumed.stale,
        result.status,
        type(result.error),
        result.result,
    ) == (
        0,
        0,
        0,
        1,
        Status.STALE,
        FixtureEvidenceMismatchError,
        None,
    )


def test_resumed_result_is_confined_to_the_owning_run_store(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    store_root = tmp_path / "store"
    store_root.mkdir()
    request = RunRequest(
        store_root / "sample-01",
        (fixture,),
        calibrate=False,
        store_root=store_root,
    )
    suite(metadata, RecordingEvents(), judge=FailingCandidateJudge()).run(request)
    store = RecordingResultStore()

    resumed = suite(
        metadata,
        RecordingEvents(),
        candidate=UnexpectedCandidate(),
        results=store,
    ).run(request)

    assert (resumed.passed, tuple(store.roots)) == (
        1,
        (("load", store_root), ("save_result", store_root)),
    )


def test_suite_resumes_at_the_judge_after_a_complete_candidate_checkpoint(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    metadata = tmp_path / "run.json"
    output = tmp_path / "results"
    failed = suite(
        metadata,
        RecordingEvents(),
        judge=FailingCandidateJudge(),
    ).run(RunRequest(output, (fixture,), calibrate=False))
    checkpoint = (
        output / fixture.name / ".claude-prompt-conformance-state/checkpoint.json"
    )
    pending = checkpoint.with_name(".checkpoint.json.interrupted.new")
    checkpoint.rename(pending)
    (output / fixture.name / "judge.stderr").unlink()
    roots = RecordingRoots()

    resumed = suite(
        metadata,
        RecordingEvents(),
        candidate=UnexpectedCandidate(),
        tasks=TaskScopes(roots),
    ).run(RunRequest(output, (fixture,), calibrate=False))

    assert (
        (failed.passed, failed.failed, failed.invalid),
        (resumed.passed, resumed.failed, resumed.invalid),
        (checkpoint.is_file(), pending.exists()),
        task_outlines(roots),
    ) == (
        (0, 0, 1),
        (1, 0, 0),
        (True, False),
        (
            TaskOutline(
                path=("conformance",),
                kind=ProgressTaskKind.SUITE,
                completed=1,
                total=1,
                outcome=TaskOutcome.PASSED,
                children=(
                    TaskOutline(
                        path=("conformance", fixture.name),
                        kind=ProgressTaskKind.FIXTURE,
                        completed=5,
                        total=5,
                        outcome=TaskOutcome.PASSED,
                        children=(
                            TaskOutline(
                                path=("conformance", fixture.name, "judge"),
                                kind=ProgressTaskKind.PHASE,
                                completed=0,
                                total=0,
                                outcome=TaskOutcome.PASSED,
                                children=(),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    )


@pytest.mark.parametrize(
    "error",
    (
        PassingJudgementInconsistentError(),
        CodexFeatureIsolationError(
            {"apps": True},
            {"apps": False},
        ),
        CodexAgentExecutionError(
            "conformance_judge",
            ProcessStartError(("/nix/codex", "exec"), 2, "/nix/codex"),
        ),
        CodexAgentExecutionError(
            "conformance_judge",
            MissingProcessStatusError(("/nix/codex", "exec")),
        ),
        JudgementEvidenceUnreadError(Path("tool-calls-candidate.txt")),
    ),
)
def test_suite_classifies_judge_failures_as_invalid_evidence(
    tmp_path: Path,
    error: ConformanceError,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    output = tmp_path / "results"
    events = RecordingEvents()
    summary = suite(
        tmp_path / "run.json",
        events,
        judge=RaisingJudge(error),
    ).run(RunRequest(output, (fixture,)))

    artefacts = output / fixture.name
    assert (summary, events.events) == (
        RunSummary(
            passed=0,
            failed=0,
            invalid=1,
            stale=0,
            results=(
                FixtureRun(
                    fixture,
                    Status.INVALID,
                    artefacts,
                    (str(error),),
                    None,
                    error,
                ),
            ),
        ),
        [
            models.TestFinished(
                fixture_name=fixture.name,
                status=Status.INVALID,
                summary=str(error),
                failures=(str(error),),
                result=None,
            ),
            SuiteFinished(0, 0, 1, 0, output, tmp_path / "run.json"),
        ],
    )


def test_suite_classifies_candidate_process_failure_as_invalid_evidence(
    tmp_path: Path,
) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    output = tmp_path / "results"
    artefacts = output / fixture.name
    error = CandidateProcessError(
        1,
        artefacts / "transcript.jsonl",
        artefacts / "candidate.stderr",
    )
    events = RecordingEvents()

    summary = suite(
        tmp_path / "run.json",
        events,
        candidate=RaisingCandidate(error),
    ).run(RunRequest(output, (fixture,), calibrate=False))

    assert (summary, events.events) == (
        RunSummary(
            passed=0,
            failed=0,
            invalid=1,
            stale=0,
            results=(
                FixtureRun(
                    fixture,
                    Status.INVALID,
                    artefacts,
                    (str(error),),
                    None,
                    error,
                ),
            ),
        ),
        [
            models.TestFinished(
                fixture_name=fixture.name,
                status=Status.INVALID,
                summary=str(error),
                failures=(str(error),),
                result=None,
            ),
            SuiteFinished(0, 0, 1, 0, output, tmp_path / "run.json"),
        ],
    )


def test_suite_cancels_processes_and_reports_an_interruption(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    output = tmp_path / "results"
    marker = tmp_path / "cancelled"
    events = RecordingEvents()
    roots = RecordingRoots()

    with pytest.raises(KeyboardInterrupt):
        suite(
            tmp_path / "run.json",
            events,
            candidate=InterruptingCandidate(),
            processes=RecordingCancellation(marker),
            tasks=TaskScopes(roots),
        ).run(RunRequest(output, (fixture,), calibrate=False))

    retained_repository = (
        output / fixture.name / "candidate" / "workspace" / "repository.json"
    )
    assert (
        events.events,
        marker.read_text(),
        retained_repository.read_text(),
        tuple(
            (
                root.outcome,
                tuple(child.outcome for child in root.children),
            )
            for root in (task.snapshot() for task in roots.roots)
        ),
    ) == (
        [models.SuiteInterrupted(output=output)],
        "cancelled\n",
        json.dumps(
            {
                "comparisonRevision": "base",
                "environmentPath": "/bin",
                "repository": {
                    "revision": "base",
                    "url": "https://example.invalid/repository.git",
                },
            },
            sort_keys=True,
        ),
        ((TaskOutcome.CANCELLED, (TaskOutcome.CANCELLED,)),),
    )


@pytest.mark.parametrize(
    ("selection", "expected"),
    [
        (Selection(names=("one",)), ("one",)),
        (Selection(categories=("clarity",)), ("one", "three")),
        (Selection(tags=("shell",)), ("two", "three")),
        (Selection(categories=("clarity",), tags=("shell",)), ("three",)),
    ],
)
def test_select_fixtures(
    tmp_path: Path, selection: Selection, expected: tuple[str, ...]
) -> None:
    fixtures = (
        make_fixture(tmp_path, name="one", category="clarity", tags=("actors",)),
        make_fixture(tmp_path, name="two", category="precision", tags=("shell",)),
        make_fixture(tmp_path, name="three", category="clarity", tags=("shell",)),
    )

    assert tuple(item.name for item in select_fixtures(fixtures, selection)) == expected


def test_prepare_output_resumes_a_marked_output(tmp_path: Path) -> None:
    output = tmp_path / "results"
    metadata = tmp_path / "run.json"
    metadata.write_text("{}\n")
    prompt_context = tmp_path / "prompt.json"
    prompt_context.write_text("{}\n")
    prepare_output(output, metadata, prompt_context)
    (output / "stale").write_text("old")

    prepare_output(output, metadata, prompt_context)

    assert tuple(sorted(path.name for path in output.iterdir())) == (
        ".claude-prompt-conformance",
        "prompt-context.json",
        "run-metadata.json",
        "stale",
    )


def test_prepare_output_rejects_an_unmarked_output_structurally(tmp_path: Path) -> None:
    output = tmp_path / "results"
    output.mkdir()

    with pytest.raises(OutputPathUnmarkedError) as raised:
        prepare_output(
            output,
            tmp_path / "run.json",
            tmp_path / "prompt.json",
        )

    assert raised.value == OutputPathUnmarkedError(output)


def test_prepare_output_recovers_an_interrupted_nested_store(tmp_path: Path) -> None:
    root = tmp_path / "results"
    root.mkdir()
    output = root / "sample-01"
    output.mkdir()
    (output / "partial-snapshot").write_text("interrupted\n")
    metadata = tmp_path / "run.json"
    metadata.write_text('{"run": 1}\n')
    prompt_context = tmp_path / "prompt.json"
    prompt_context.write_text('{"prompt": 2}\n')

    prepare_output(
        output,
        metadata,
        prompt_context,
        root=root,
    )

    assert tuple(
        (path.name, path.read_text()) for path in sorted(output.iterdir())
    ) == (
        (
            ".claude-prompt-conformance",
            '{"promptContext": "prompt-context.json", "runMetadata": "run-metadata.json"}\n',
        ),
        ("prompt-context.json", '{"prompt": 2}\n'),
        ("run-metadata.json", '{"run": 1}\n'),
    )
