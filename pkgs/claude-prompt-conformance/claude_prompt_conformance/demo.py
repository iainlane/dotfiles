"""Scripted capabilities which demonstrate a run without model requests.

`--demo` drives the ordinary frontend, result store, and orchestration with
these scripted stand-ins for the real agents. Nothing here reads a
credential, opens a network connection, or starts a subprocess; the pauses
exist only so the progress display has time to show each phase.

The demonstration work is drawn from each fixture's own vetted data: the
candidate's response is the known-good reference response, and the changelog
and changed files are read out of that response, so a demo run presents the
fixture's real historical work.
"""

import json
import re
import time
from dataclasses import dataclass
from pathlib import Path

from .backend import ConformanceSuite
from .checkpoints import JsonFixtureResultStore
from .composition import Application
from .errors import ConformanceError
from .models import (
    CandidateResult,
    FailureOrigin,
    Fixture,
    InstancePaths,
    JudgedCriterion,
    Judgement,
    JudgementSubject,
    PromptProposal,
    RepositorySpec,
    RuntimeConfiguration,
    VerificationResult,
    WorkspaceEvidence,
)
from .ports import ActivityReporter, AgentSlots, EventSink
from .progress import TaskScopes
from .workspace import DirectoryInstanceFactory

CANDIDATE_ACTIVITIES = (
    "Read: the task and the files it names",
    "Bash: reproduce the reported failure",
    "Edit: fix the cause of the failure",
    "Bash: run the checks the repository provides",
)

FALLBACK_RESPONSE = "The task is complete and the repository checks pass.\n"

_REVISION_DOCUMENT = "demo-repository.json"

_WORK_DOCUMENT = "demo-work.json"

_COMMIT_SENTENCE = re.compile(r"committed[^`]*`(.+?)`[.;]", re.DOTALL)

_QUOTED_TOKEN = re.compile(r"`([^`\s:=(){};,]+)`")


@dataclass(eq=True)
class DemoReferenceUnmatchedError(ConformanceError):
    subject: str

    def __str__(self) -> str:
        return f"demo reference subject {self.subject!r} matches no declared response"


@dataclass(eq=True)
class DemoImprovementUnsupportedError(ConformanceError):
    def __str__(self) -> str:
        return "prompt improvement is not available in a demo run"


@dataclass(frozen=True)
class DemoPacing:
    """Scale the scripted pauses; tests run the demo with a scale of zero."""

    scale: float = 1.0

    def pause(self, seconds: float) -> None:
        if self.scale > 0:
            time.sleep(seconds * self.scale)


@dataclass(frozen=True)
class DemoStory:
    """The demonstration work for one fixture, drawn from its vetted data."""

    response: str
    revision: str
    subject: str | None
    files: tuple[str, ...]


def demo_story(fixture: Fixture) -> DemoStory:
    """Assemble the candidate work a demo run presents for one fixture.

    The response is the fixture's known-good reference response, and the
    commit subject, changed files, and head revision come from that reference,
    so the presented work is the fixture's real historical fix.
    """

    reference = next(
        (
            candidate
            for candidate in fixture.calibration
            if all(passed for _, passed in candidate.expected_criteria)
        ),
        None,
    )
    if reference is None:
        return DemoStory(FALLBACK_RESPONSE, fixture.repository.revision, None, ())

    response = reference.response.read_text()
    subject = commit_subject(response)
    files: tuple[str, ...] = ()
    if subject is not None:
        files = changed_files(response) or _verification_files(fixture)

    return DemoStory(response, reference.repository.revision, subject, files)


def commit_subject(response: str) -> str | None:
    """Read the commit subject a response quotes, if it quotes one.

    The vetted responses name their commit in backticks in a sentence such as
    "I committed the change as `...`". The subject itself may contain
    backticked code, so the match ends at the closing backtick before the
    sentence's terminator.
    """

    match = _COMMIT_SENTENCE.search(response)
    if match is None:
        return None

    return " ".join(match.group(1).split())


def changed_files(response: str) -> tuple[str, ...]:
    """Collect the file paths a response mentions in backticks."""

    files: list[str] = []
    for token in _QUOTED_TOKEN.findall(response):
        if _plausible_file(token) and token not in files:
            files.append(token)

    return tuple(files[:6])


def _verification_files(fixture: Fixture) -> tuple[str, ...]:
    """Collect the file paths the fixture's verification commands name."""

    files: list[str] = []
    for check in fixture.verification:
        for argument in check.command[1:]:
            if _plausible_file(argument) and argument not in files:
                files.append(argument)

    return tuple(files[:6])


def _plausible_file(token: str) -> bool:
    if token.startswith("-") or ".." in token:
        return False
    if token.startswith("./"):
        return False
    if token.startswith(".") and "/" not in token:
        return False

    root, _, extension = token.rpartition(".")
    return bool(root) and re.fullmatch(r"[a-z0-9]{1,10}", extension) is not None


@dataclass(frozen=True)
class DemoRepositories:
    pacing: DemoPacing

    def materialise(
        self,
        repository: RepositorySpec,
        destination: Path,
        control: Path,
        environment_path: str,
        comparison_revision: str,
    ) -> None:
        self.pacing.pause(0.8)

        (destination / _REVISION_DOCUMENT).write_text(
            json.dumps({"revision": repository.revision})
        )


class DemoOverlay:
    def install(self, workspace: Path) -> None:
        pass


@dataclass(frozen=True)
class DemoPreparer:
    pacing: DemoPacing

    def prepare(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> None:
        self.pacing.pause(0.7)


@dataclass(frozen=True)
class DemoCandidate:
    pacing: DemoPacing

    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        for index, description in enumerate(CANDIDATE_ACTIVITIES, start=1):
            identifier = f"demo-{index}"

            activity.start_activity(identifier, description)
            self.pacing.pause(1.5)
            activity.finish_activity(identifier, f"{description} finished")

        story = demo_story(fixture)
        (instance.workspace / _WORK_DOCUMENT).write_text(
            json.dumps(
                {
                    "revision": story.revision,
                    "subject": story.subject,
                    "files": list(story.files),
                }
            )
        )

        transcript = artefacts / "transcript.jsonl"
        trace = artefacts / "trace.jsonl"
        transcript.write_text("{}\n")
        trace.write_text("{}\n")

        return CandidateResult(story.response, transcript, trace)


@dataclass(frozen=True)
class DemoInspector:
    pacing: DemoPacing

    def inspect(
        self,
        workspace: Path,
        base_revision: str,
        artefacts: Path,
        environment_path: str,
    ) -> WorkspaceEvidence:
        self.pacing.pause(0.6)

        work = workspace / _WORK_DOCUMENT
        if work.exists():
            return _candidate_evidence(
                json.loads(work.read_text()),
                base_revision,
                artefacts,
            )

        return _reference_evidence(workspace, base_revision, artefacts)


def _candidate_evidence(
    story: dict[str, object],
    base_revision: str,
    artefacts: Path,
) -> WorkspaceEvidence:
    revision = str(story["revision"])
    subject = story["subject"]
    raw_files = story["files"]
    files = (
        tuple(str(name) for name in raw_files) if isinstance(raw_files, list) else ()
    )

    snapshot = artefacts / "workspace-snapshot"
    snapshot.mkdir()
    for name in files:
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"Contents at {revision}.\n")

    diff = artefacts / "diff.patch"
    diff.write_text("".join(f"--- a/{name}\n+++ b/{name}\n" for name in files))

    commits = artefacts / "commits.txt"
    commits.write_text(f"{revision[:7]} {subject}\n" if subject else "")

    return WorkspaceEvidence(
        workspace=snapshot,
        base_revision=base_revision,
        head_revision=revision,
        status="\n".join(f" M {name}" for name in files),
        diff=diff,
        commits=commits,
        changed_files=files,
    )


def _reference_evidence(
    workspace: Path,
    base_revision: str,
    artefacts: Path,
) -> WorkspaceEvidence:
    """Build minimal evidence for a reference subject; it is never displayed."""

    revision_document = json.loads((workspace / _REVISION_DOCUMENT).read_text())
    head_revision = revision_document["revision"]

    snapshot = artefacts / "workspace-snapshot"
    snapshot.mkdir()

    diff = artefacts / "diff.patch"
    diff.write_text("")

    commits = artefacts / "commits.txt"
    commits.write_text("")

    return WorkspaceEvidence(
        workspace=snapshot,
        base_revision=base_revision,
        head_revision=head_revision,
        status="",
        diff=diff,
        commits=commits,
        changed_files=(),
    )


@dataclass(frozen=True)
class DemoVerifier:
    pacing: DemoPacing

    def verify(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> tuple[VerificationResult, ...]:
        results = []
        for index, check in enumerate(fixture.verification):
            self.pacing.pause(0.5)

            stdout = artefacts / f"verification-{index}.stdout"
            stderr = artefacts / f"verification-{index}.stderr"
            stdout.write_text(f"{check.name}: passed\n")
            stderr.write_text("")

            results.append(
                VerificationResult(
                    name=check.name,
                    command=check.command,
                    kind=check.kind,
                    expected_return_code=check.expected_return_code,
                    return_code=check.expected_return_code,
                    stdout=stdout,
                    stderr=stderr,
                )
            )

        return tuple(results)


@dataclass(frozen=True)
class DemoJudge:
    pacing: DemoPacing

    def assess(
        self,
        fixture: Fixture,
        subject: JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> Judgement:
        if subject.name == "candidate":
            self.pacing.pause(2.0)
            return demo_judgement(fixture)

        self.pacing.pause(1.2)

        for candidate in fixture.calibration:
            if candidate.response.read_text() == subject.response:
                return reference_judgement(candidate.expected_criteria)

        raise DemoReferenceUnmatchedError(subject.name)


def demo_judgement(fixture: Fixture) -> Judgement:
    """Pass every criterion of the fixture for the demonstration candidate."""

    return Judgement(
        criteria=tuple(
            JudgedCriterion(
                identifier=criterion.identifier,
                passed=True,
                reason="The recorded work meets this criterion.",
                evidence=(),
            )
            for criterion in fixture.criteria
        ),
        failure_origin=FailureOrigin.NONE,
        summary=f"All {len(fixture.criteria)} criteria met.",
        recommendation="No changes are needed.",
        counterfactual="",
        corrected_response="",
        prompt_observations=(),
    )


def reference_judgement(expected: tuple[tuple[str, bool], ...]) -> Judgement:
    """Return exactly the verdicts a reference subject declares."""

    passed = all(verdict for _, verdict in expected)
    return Judgement(
        criteria=tuple(
            JudgedCriterion(
                identifier=identifier,
                passed=verdict,
                reason="Reference verdict.",
                evidence=(),
            )
            for identifier, verdict in expected
        ),
        failure_origin=FailureOrigin.NONE if passed else FailureOrigin.CANDIDATE,
        summary="Reference judgement.",
        recommendation=(
            "No changes are needed." if passed else "Apply the expected fix."
        ),
        counterfactual="",
        corrected_response="",
        prompt_observations=(),
    )


class DemoProcesses:
    def cancel(self) -> None:
        pass


class DemoImprover:
    def propose(
        self,
        configuration: RuntimeConfiguration,
        evidence: Path,
        environment_path: str,
        instance: InstancePaths,
        artefacts: Path,
        angle: str,
    ) -> PromptProposal:
        raise DemoImprovementUnsupportedError


class DemoVariants:
    def build(
        self,
        configuration: RuntimeConfiguration,
        proposal: PromptProposal,
        artefacts: Path,
        root: Path,
    ) -> RuntimeConfiguration:
        raise DemoImprovementUnsupportedError


@dataclass(frozen=True)
class DemoApplicationFactory:
    """Construct applications whose capabilities are scripted stand-ins."""

    tasks: TaskScopes
    slots: AgentSlots
    pacing: DemoPacing = DemoPacing()

    def __call__(
        self,
        configuration: RuntimeConfiguration,
        events: EventSink,
    ) -> Application:
        instances = DirectoryInstanceFactory()
        return Application(
            suite=ConformanceSuite(
                instances=instances,
                repositories=DemoRepositories(self.pacing),
                overlay=DemoOverlay(),
                preparer=DemoPreparer(self.pacing),
                candidate=DemoCandidate(self.pacing),
                inspector=DemoInspector(self.pacing),
                verifier=DemoVerifier(self.pacing),
                judge=DemoJudge(self.pacing),
                events=events,
                tasks=self.tasks,
                processes=DemoProcesses(),
                slots=self.slots,
                results=JsonFixtureResultStore(),
                run_metadata=configuration.run_metadata,
                prompt_context=configuration.prompt_context,
            ),
            improver=DemoImprover(),
            variants=DemoVariants(),
            instances=instances,
            processes=DemoProcesses(),
        )
