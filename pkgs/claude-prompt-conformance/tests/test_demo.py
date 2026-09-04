from dataclasses import dataclass, field, replace
from pathlib import Path

import pytest

from claude_prompt_conformance.backend import (
    ConformanceSuite,
    RunRequest,
)
from claude_prompt_conformance.checkpoints import JsonFixtureResultStore
from claude_prompt_conformance.cli import (
    DemoImprovementConflictError,
    demo_arguments,
    parser,
    validate_demo_options,
)
from claude_prompt_conformance.demo import (
    CANDIDATE_ACTIVITIES,
    DemoCandidate,
    DemoInspector,
    DemoJudge,
    DemoOverlay,
    DemoPacing,
    DemoPreparer,
    DemoRepositories,
    DemoStory,
    DemoVerifier,
    demo_story,
)
from claude_prompt_conformance.models import (
    CandidateResult,
    Fixture,
    VerificationCommand,
    VerificationKind,
)
from claude_prompt_conformance.models import (
    TestStatus as Status,
)
from claude_prompt_conformance.progress import TaskScopes
from claude_prompt_conformance.workspace import DirectoryInstanceFactory

from .helpers import (
    FakeProcesses,
    RecordingEvents,
    RecordingRoots,
    RecordingSlots,
    make_fixture,
)

INSTANT = DemoPacing(scale=0)

COMMIT_SUBJECT = "fix(backup): ask tar for numeric owners by its own name"

CHANGED_FILE = "lib/r2-upload.sh"


def vetted_fixture(root: Path) -> Fixture:
    """A fixture whose known-good reference quotes its commit and a file."""

    fixture = make_fixture(root)
    fixture.calibration[0].response.write_text(
        f"The uploader now passes GNU tar's `--numeric-owner` option; the\n"
        f"failing `--numeric-ids` spelling belongs to rsync. `{CHANGED_FILE}`\n"
        f"is the only changed file.\n"
        f"\n"
        f"I committed the focused fix as\n"
        f"`{COMMIT_SUBJECT}`.\n"
        f"The repository checks pass.\n"
    )
    return fixture


def known_good(fixture: Fixture) -> tuple[str, str]:
    """The reference revision and response text the demo should present."""

    reference = fixture.calibration[0]
    return reference.repository.revision, reference.response.read_text()


def demo_suite(metadata: Path, events: RecordingEvents) -> ConformanceSuite:
    metadata.write_text('{"run":"demo"}\n')
    prompt_context = metadata.with_name("prompt-context-source.json")
    prompt_context.write_text('{"prompt":"demo"}\n')
    return ConformanceSuite(
        instances=DirectoryInstanceFactory(),
        repositories=DemoRepositories(INSTANT),
        overlay=DemoOverlay(),
        preparer=DemoPreparer(INSTANT),
        candidate=DemoCandidate(INSTANT),
        inspector=DemoInspector(INSTANT),
        verifier=DemoVerifier(INSTANT),
        judge=DemoJudge(INSTANT),
        events=events,
        tasks=TaskScopes(RecordingRoots()),
        processes=FakeProcesses(),
        slots=RecordingSlots(),
        results=JsonFixtureResultStore(),
        run_metadata=metadata,
        prompt_context=prompt_context,
    )


def test_demo_story_presents_the_vetted_reference_work(tmp_path: Path) -> None:
    fixture = vetted_fixture(tmp_path / "fixtures")

    revision, response = known_good(fixture)
    assert demo_story(fixture) == DemoStory(
        response=response,
        revision=revision,
        subject=COMMIT_SUBJECT,
        files=(CHANGED_FILE,),
    )


def test_demo_story_without_authorship_presents_no_change(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")

    revision, response = known_good(fixture)
    assert demo_story(fixture) == DemoStory(
        response=response,
        revision=revision,
        subject=None,
        files=(),
    )


def test_demo_story_falls_back_to_verification_paths(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    fixture.calibration[0].response.write_text(
        f"I committed the change as `{COMMIT_SUBJECT}`.\n"
    )
    fixture = replace(
        fixture,
        verification=(
            VerificationCommand(
                "shell syntax",
                ("bash", "-n", CHANGED_FILE),
                VerificationKind.GATE,
                0,
                ".",
            ),
        ),
    )

    revision, response = known_good(fixture)
    assert demo_story(fixture) == DemoStory(
        response=response,
        revision=revision,
        subject=COMMIT_SUBJECT,
        files=(CHANGED_FILE,),
    )


def test_demo_run_presents_the_reference_work_and_passes(tmp_path: Path) -> None:
    fixture = vetted_fixture(tmp_path / "fixtures")
    events = RecordingEvents()
    output = tmp_path / "results"

    summary = demo_suite(tmp_path / "run.json", events).run(
        RunRequest(output, (fixture,))
    )

    revision, response = known_good(fixture)
    artefacts = output / fixture.name
    changelog = (artefacts / "commits.txt").read_text()
    result = summary.results[0].result
    assert result is not None
    assert (
        summary.passed,
        summary.failed,
        summary.invalid,
        summary.stale,
        summary.results[0].status,
        result.candidate,
        result.evidence.head_revision,
        result.evidence.changed_files,
        COMMIT_SUBJECT in changelog and revision[:7] in changelog,
    ) == (
        1,
        0,
        0,
        0,
        Status.PASSED,
        CandidateResult(
            response,
            artefacts / "transcript.jsonl",
            artefacts / "trace.jsonl",
        ),
        revision,
        (CHANGED_FILE,),
        True,
    )


def test_demo_judgement_passes_exactly_the_fixture_criteria(tmp_path: Path) -> None:
    fixture = vetted_fixture(tmp_path / "fixtures")
    events = RecordingEvents()

    summary = demo_suite(tmp_path / "run.json", events).run(
        RunRequest(tmp_path / "results", (fixture,))
    )

    result = summary.results[0].result
    assert result is not None
    assert tuple(
        (criterion.identifier, criterion.passed)
        for criterion in result.judgement.criteria
    ) == tuple((criterion.identifier, True) for criterion in fixture.criteria)


def test_demo_calibration_returns_the_declared_expectations(tmp_path: Path) -> None:
    fixture = vetted_fixture(tmp_path / "fixtures")
    events = RecordingEvents()

    summary = demo_suite(tmp_path / "run.json", events).run(
        RunRequest(tmp_path / "results", (fixture,))
    )

    result = summary.results[0].result
    assert result is not None
    assert tuple(
        (
            assessment.candidate,
            tuple(
                sorted(
                    (criterion.identifier, criterion.passed)
                    for criterion in assessment.judgement.criteria
                )
            ),
        )
        for assessment in result.calibration
    ) == tuple(
        (candidate.name, candidate.expected_criteria)
        for candidate in fixture.calibration
    )


def test_demo_verification_reflects_the_fixture_commands(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    events = RecordingEvents()

    summary = demo_suite(tmp_path / "run.json", events).run(
        RunRequest(tmp_path / "results", (fixture,))
    )

    result = summary.results[0].result
    assert result is not None
    assert tuple(
        (item.name, item.command, item.kind, item.return_code, item.flaky)
        for item in result.verification
    ) == tuple(
        (
            command.name,
            command.command,
            command.kind,
            command.expected_return_code,
            False,
        )
        for command in fixture.verification
    )


@dataclass
class RecordingActivity:
    records: list[tuple[str, str, str]] = field(default_factory=list)

    def start_activity(self, identifier: str, description: str) -> None:
        self.records.append(("start", identifier, description))

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None:
        self.records.append(("heartbeat", identifier, str(elapsed_seconds)))

    def finish_activity(self, identifier: str, detail: str) -> None:
        self.records.append(("finish", identifier, detail))


def test_demo_candidate_reports_every_scripted_activity(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path / "fixtures")
    instance = DirectoryInstanceFactory().create("candidate", tmp_path / "results")
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    activity = RecordingActivity()

    result = DemoCandidate(INSTANT).run(fixture, instance, artefacts, activity)

    _, response = known_good(fixture)
    assert (result, activity.records) == (
        CandidateResult(
            response,
            artefacts / "transcript.jsonl",
            artefacts / "trace.jsonl",
        ),
        [
            record
            for index, description in enumerate(CANDIDATE_ACTIVITIES, start=1)
            for record in (
                ("start", f"demo-{index}", description),
                ("finish", f"demo-{index}", f"{description} finished"),
            )
        ],
    )


def test_demo_options_reject_improvement() -> None:
    with pytest.raises(DemoImprovementConflictError) as raised:
        validate_demo_options(demo=True, improve=True)

    assert raised.value == DemoImprovementConflictError()


def test_demo_needs_no_output_argument() -> None:
    arguments = parser().parse_args(["configuration.json", "--demo"])

    assert (arguments.demo, arguments.output) == (True, None)


def test_demo_treats_every_positional_as_a_test_name() -> None:
    arguments = parser().parse_args(
        ["configuration.json", "first-test", "second-test", "--demo"]
    )

    adjusted = demo_arguments(arguments)

    assert (adjusted.output, adjusted.tests) == (None, ["first-test", "second-test"])
