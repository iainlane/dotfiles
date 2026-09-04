import errno
from dataclasses import dataclass, field, replace
from enum import StrEnum
from pathlib import Path
from threading import Barrier, Event, Lock

import msgspec
import pytest

from claude_prompt_conformance.agents.improver import IMPROVER_ANGLES
from claude_prompt_conformance.backend import FixtureRun, RunRequest, RunSummary
from claude_prompt_conformance.codex_identity import RunCancellation
from claude_prompt_conformance.composition import Application as ProductionApplication
from claude_prompt_conformance.composition import (
    ApplicationFactory,
    RunAuthentication,
    platform_claude_credentials,
)
from claude_prompt_conformance.credential_lock import (
    ClaudeCredentialRefreshLock,
    ClaudeCredentialStorageLock,
)
from claude_prompt_conformance.credentials import ClaudeCredential
from claude_prompt_conformance.experiments.models import (
    AcceptanceFailure,
    AcceptanceReport,
    CriterionComparison,
    DraftReport,
    ImprovementSummary,
)
from claude_prompt_conformance.identities import (
    AnthropicOAuthRefresher,
    ClaudeFileCredentialStore,
    ClaudeOAuthIdentity,
)
from claude_prompt_conformance.improvement import (
    DraftOutcome,
    ImprovementCurrentPromptInvalidError,
    ImprovementEvidenceReadError,
    ImprovementProposalLimitError,
    ImprovementRequest,
    ImprovementReservedChecksEmptyError,
    ImprovementSampleLimitError,
    ImprovementWorkingExamplesEmptyError,
    PromptImprovementSuite,
    bounded_evidence,
    compare_results,
    fixtures_by_use,
    improvement_children,
    prompt_tree_diff,
    reserved_results_accepted,
    summaries_have_complete_evidence,
    validate_bounds,
    validate_fixture_sets,
    winning_draft,
)
from claude_prompt_conformance.models import (
    CandidateResult,
    ClaudeConfiguration,
    CodexAgentConfiguration,
    CodexConfiguration,
    CodexHostConfiguration,
    Fixture,
    FixtureUse,
    ImprovementFinished,
    InstancePaths,
    IsolationConfiguration,
    PromptProposal,
    PromptVariantConfiguration,
    RuntimeConfiguration,
)
from claude_prompt_conformance.models import (
    TestFinished as Finished,
)
from claude_prompt_conformance.models import (
    TestResult as Result,
)
from claude_prompt_conformance.models import (
    TestStatus as Status,
)
from claude_prompt_conformance.ports import EventSink, ProcessController
from claude_prompt_conformance.process import RunCancelled
from claude_prompt_conformance.progress import (
    TaskKind,
    TaskOutcome,
    TaskRun,
    TaskScopes,
)
from claude_prompt_conformance.slots import SlotPool
from claude_prompt_conformance.task_children import ChildAllocation, FixedTaskChildren

from .helpers import (
    FakeInstances,
    FakeProcesses,
    RecordingEvents,
    RecordingRoots,
    RecordingSlots,
    TaskOutline,
    codex_identity,
    judgement,
    make_fixture,
    task_outlines,
    verification_results,
    workspace_evidence,
)

WAIT_SECONDS = 30


class GateOutcome(StrEnum):
    """How one evaluation's deterministic gate behaved in every sample."""

    PASSED = "passed"
    FAILED = "failed"
    QUARANTINED = "quarantined"


@dataclass
class Script:
    """Scripted sample outcomes, keyed by prompt source and fixture name."""

    passes: dict[str, dict[str, int]] = field(default_factory=dict)
    default: int = 5
    barrier: Barrier | None = None
    barrier_prefix: str = ""
    started: Event | None = None
    started_prefix: str = ""
    lock: Lock = field(default_factory=Lock)
    evaluations: list[tuple[str, str, bool]] = field(default_factory=list)

    def sample_passes(self, prompt: str, fixture: str) -> int:
        """Return how many samples of one prompt pass one fixture's criterion."""

        return self.passes.get(prompt, {}).get(fixture, self.default)

    def observe(self, prompt: str, evaluation: str, calibrate: bool) -> None:
        with self.lock:
            self.evaluations.append((prompt, evaluation, calibrate))


@dataclass
class ScriptedSuite:
    """Answer every prompt evaluation from a scripted table of outcomes."""

    configuration: RuntimeConfiguration
    events: RecordingEvents
    script: Script

    def run(self, request: RunRequest) -> RunSummary:
        prompt = self.configuration.variant.prompt_source.name
        store_root = request.store_root or request.output
        relative = request.output.relative_to(store_root).as_posix()
        sample = int(request.output.name.removeprefix("sample-"))
        self.script.observe(prompt, relative, request.calibrate)
        if self.script.started is not None and relative.startswith(
            self.script.started_prefix
        ):
            self.script.started.set()
        if self.script.barrier is not None and relative.startswith(
            self.script.barrier_prefix
        ):
            self.script.barrier.wait()

        request.output.mkdir(parents=True)
        runs = tuple(
            self._run_fixture(
                fixture,
                request.output,
                sample <= self.script.sample_passes(prompt, fixture.name),
            )
            for fixture in request.fixtures
        )
        return RunSummary(
            passed=sum(run.status is Status.PASSED for run in runs),
            failed=sum(run.status is Status.FAILED for run in runs),
            invalid=0,
            stale=0,
            results=runs,
        )

    def _run_fixture(
        self,
        fixture: Fixture,
        output: Path,
        passed: bool,
    ) -> FixtureRun:
        artefacts = output / fixture.name
        artefacts.mkdir()
        candidate = CandidateResult(
            "Completed.",
            artefacts / "transcript.jsonl",
            artefacts / "actions.json",
        )
        candidate.transcript.write_text("")
        candidate.trace.write_text("[]")
        evidence = workspace_evidence("base", "head", artefacts)
        evidence.diff.write_text("diff\n")
        evidence.commits.write_text("commit\n")
        verification = verification_results("head", artefacts)
        for check in verification:
            check.stdout.write_text("ok\n")
            check.stderr.write_text("")
        result = Result(
            candidate, evidence, verification, judgement(passed, "head"), ()
        )
        status = Status.PASSED if passed else Status.FAILED
        failures = () if passed else ("works: assessment",)
        self.events.emit(Finished(fixture.name, status, "assessment", failures, result))
        return FixtureRun(fixture, status, artefacts, failures, result, None)


@dataclass
class CancellingSuite(ScriptedSuite):
    """Fail one working sample while a sibling waits to observe cancellation."""

    started: Event = field(default_factory=Event)
    cancellation: Event = field(default_factory=Event)
    marker: Path = Path()

    def run(self, request: RunRequest) -> RunSummary:
        store_root = request.store_root or request.output
        relative = request.output.relative_to(store_root).as_posix()
        if relative == "current-prompt/sample-02":
            self.started.wait(WAIT_SECONDS)
            raise ImprovementEvidenceReadError(request.output, errno.EIO)

        if relative == "current-prompt/sample-03":
            self.started.set()
            self.cancellation.wait(WAIT_SECONDS)
            self.marker.write_text("cancelled\n")

        return super().run(request)


@dataclass
class UncalibratedSuite(ScriptedSuite):
    """Report one sample as invalid while a sibling waits to be cancelled."""

    started: Event = field(default_factory=Event)
    cancellation: Event = field(default_factory=Event)
    marker: Path = Path()

    def run(self, request: RunRequest) -> RunSummary:
        store_root = request.store_root or request.output
        relative = request.output.relative_to(store_root).as_posix()
        if relative == "current-prompt/sample-02":
            self.started.wait(WAIT_SECONDS)
            return RunSummary(passed=0, failed=0, invalid=1, stale=0, results=())

        if relative == "current-prompt/sample-03":
            self.started.set()
            self.cancellation.wait(WAIT_SECONDS)
            self.marker.write_text("cancelled\n")

        return super().run(request)


@dataclass
class UncalibratedRaisingSuite(ScriptedSuite):
    """Report one sample invalid while a cancelled sibling raises RunCancelled."""

    started: Event = field(default_factory=Event)
    cancellation: Event = field(default_factory=Event)

    def run(self, request: RunRequest) -> RunSummary:
        store_root = request.store_root or request.output
        relative = request.output.relative_to(store_root).as_posix()
        if relative == "current-prompt/sample-02":
            self.started.wait(WAIT_SECONDS)
            return RunSummary(passed=0, failed=0, invalid=1, stale=0, results=())

        if relative == "current-prompt/sample-03":
            self.started.set()
            self.cancellation.wait(WAIT_SECONDS)
            raise RunCancelled

        return super().run(request)


@dataclass(frozen=True)
class CancellingProcesses:
    cancellation: Event

    def cancel(self) -> None:
        self.cancellation.set()


@dataclass
class ScriptedImprover:
    """Return one prepared proposal for each fixed improver angle."""

    proposals: tuple[PromptProposal, ...]
    barrier: Barrier | None = None
    awaits: Event | None = None
    lock: Lock = field(default_factory=Lock)
    angles: list[str] = field(default_factory=list)

    def propose(
        self,
        configuration: RuntimeConfiguration,
        evidence: Path,
        environment_path: str,
        instance: InstancePaths,
        artefacts: Path,
        angle: str,
    ) -> PromptProposal:
        draft = IMPROVER_ANGLES.index(angle)
        with self.lock:
            self.angles.append(angle)
        if self.awaits is not None and not self.awaits.wait(WAIT_SECONDS):
            raise AssertionError("the awaited evaluation never started")
        if self.barrier is not None and draft < self.barrier.parties:
            self.barrier.wait()
        return self.proposals[draft]


@dataclass(frozen=True)
class ScriptedVariants:
    """Build the prepared prompt tree belonging to one proposal."""

    sources: dict[str, RuntimeConfiguration]

    def build(
        self,
        configuration: RuntimeConfiguration,
        proposal: PromptProposal,
        artefacts: Path,
        root: Path,
    ) -> RuntimeConfiguration:
        artefacts.mkdir()
        return self.sources[proposal.title]


@dataclass(frozen=True)
class Application:
    suite: ScriptedSuite
    improver: ScriptedImprover
    variants: ScriptedVariants
    instances: FakeInstances
    processes: ProcessController


def configuration(
    tmp_path: Path, prompt_source: Path, name: str
) -> RuntimeConfiguration:
    settings = tmp_path / f"{name}-settings.json"
    settings.write_text("{}")
    candidate_context = tmp_path / f"{name}-context"
    candidate_context.mkdir()
    source = tmp_path / f"{name}-configuration.json"
    source.write_text("{}")
    run_metadata = tmp_path / "run.json"
    run_metadata.write_text("{}\n")
    prompt_context = tmp_path / "prompt.json"
    prompt_context.write_text("{}\n")
    return RuntimeConfiguration(
        fixture_manifest=tmp_path / "fixtures.json",
        run_metadata=run_metadata,
        prompt_context=prompt_context,
        candidate_context=candidate_context,
        workspace_overlay=tmp_path / "overlay",
        git_program="git",
        claude=ClaudeConfiguration(
            "claude",
            "bash",
            settings,
            "sonnet",
            "medium",
            "0.75",
            "Plain technical prose",
            "https://claude.invalid/oauth/token",
            "claude-client",
        ),
        codex=CodexConfiguration(
            "codex",
            "mcp",
            CodexAgentConfiguration("gpt-5.6-terra", "high", "fast", "low", 272000),
            CodexAgentConfiguration("gpt-5.6-sol", "high", "fast", "low", 272000),
            tmp_path / "schema.json",
            tmp_path / "proposal-schema.json",
            tmp_path / "ca-bundle.crt",
            "https://codex.invalid/oauth/token",
            "codex-client",
        ),
        isolation=IsolationConfiguration("direct", None),
        variant=PromptVariantConfiguration(
            "nix",
            tmp_path / "nixpkgs",
            tmp_path / "variant.nix",
            tmp_path / "prompt-environment.nix",
            prompt_source,
        ),
        source=source,
    )


def prompt_source(root: Path, name: str, text: str) -> Path:
    """Materialise one controlled prompt tree with a single instruction file."""

    source = root / name
    (source / "instructions").mkdir(parents=True)
    (source / "output-style").mkdir()
    (source / "instructions" / "AGENTS.md").write_text(text)
    return source


def proposal(index: int) -> PromptProposal:
    """Build one draft proposal whose patch rewrites the single instruction."""

    return PromptProposal(
        no_change=False,
        title=f"draft {index}",
        observations=(f"Draft {index} observed contradictory handoffs.",),
        change=f"Apply draft {index}.",
        reasoning="The final report can be checked against the action evidence.",
        risks=("Handoffs may become longer.",),
        patch=(
            "--- a/instructions/AGENTS.md\n"
            "+++ b/instructions/AGENTS.md\n"
            "@@ -1 +1 @@\n"
            "-Original\n"
            f"+Draft {index}\n"
        ),
    )


def no_change_proposal() -> PromptProposal:
    return PromptProposal(
        no_change=True,
        title="no general prompt change is justified",
        observations=("The failures do not share a prompt-level cause.",),
        change="",
        reasoning="A prompt change would encode fixture-specific behaviour.",
        risks=(),
        patch="",
    )


@dataclass(frozen=True)
class Tournament:
    """The scripted world one improvement run is executed against."""

    original: RuntimeConfiguration
    fixtures: tuple[Fixture, ...]
    script: Script
    improver: ScriptedImprover
    variants: ScriptedVariants
    events: RecordingEvents
    roots: RecordingRoots
    slots: RecordingSlots
    output: Path

    def applications(
        self,
        current: RuntimeConfiguration,
        events: EventSink,
    ) -> Application:
        return Application(
            suite=ScriptedSuite(current, self.events, self.script),
            improver=self.improver,
            variants=self.variants,
            instances=FakeInstances(),
            processes=FakeProcesses(),
        )

    def run(self, *, proposals: int, samples: int) -> ImprovementSummary:
        return PromptImprovementSuite(
            self.applications,
            self.events,
            TaskScopes(self.roots),
            self.slots,
        ).run(
            self.original,
            ImprovementRequest(
                output=self.output,
                fixtures=self.fixtures,
                proposals=proposals,
                samples=samples,
            ),
        )


def tournament(
    tmp_path: Path,
    *,
    passes: dict[str, dict[str, int]] | None = None,
    proposals: tuple[PromptProposal, ...] | None = None,
    script: Script | None = None,
    improver: ScriptedImprover | None = None,
    slots: RecordingSlots | None = None,
) -> Tournament:
    """Prepare an improvement run whose evaluations follow a fixed script."""

    drafts = proposals or tuple(proposal(index) for index in (1, 2, 3))
    sources = tmp_path / "sources"
    original = configuration(
        tmp_path,
        prompt_source(sources, "base-source", "Original\n"),
        "original",
    )
    variants = {
        draft.title: configuration(
            tmp_path,
            prompt_source(sources, f"{draft.title}-source", f"Draft {index}\n"),
            f"variant-{index}",
        )
        for index, draft in enumerate(drafts, start=1)
        if not draft.no_change
    }
    fixtures = (
        replace(
            make_fixture(tmp_path / "fixtures", name="working"),
            use=FixtureUse.WORKING,
        ),
        replace(
            make_fixture(tmp_path / "fixtures", name="reserved"),
            use=FixtureUse.RESERVED,
        ),
    )
    return Tournament(
        original=original,
        fixtures=fixtures,
        script=script or Script(passes=passes or {}),
        improver=improver or ScriptedImprover(drafts),
        variants=ScriptedVariants(variants),
        events=RecordingEvents(),
        roots=RecordingRoots(),
        slots=slots or RecordingSlots(),
        output=tmp_path / "results",
    )


def decode_summary(path: Path) -> ImprovementSummary:
    """Read a retained improvement summary back into its domain value."""

    return msgspec.json.decode(
        path.read_bytes(),
        type=ImprovementSummary,
        dec_hook=lambda kind, value: Path(str(value)) if kind is Path else value,
    )


def draft_report(
    draft: str,
    title: str,
    baseline: int,
    proposed: int,
    *,
    accepted: bool,
    failures: tuple[AcceptanceFailure, ...] = (),
) -> DraftReport:
    """Build the report one draft is required to produce for the working example."""

    change = proposed - baseline
    return DraftReport(
        draft=draft,
        title=title,
        acceptance=AcceptanceReport(
            accepted=accepted,
            failures=failures,
            comparisons=(
                CriterionComparison(
                    fixture="working",
                    criterion="works",
                    baseline_passed=baseline,
                    baseline_total=5,
                    proposed_passed=proposed,
                    proposed_total=5,
                    change=change,
                    flaky=0 < baseline < 5,
                ),
            ),
            decisive_improvement=change if change >= 3 else 0,
            noise_regressions=1 if change == -1 else 0,
        ),
    )


def test_improvement_progress_reserves_the_current_prompt_drafts_and_checks() -> None:
    assert improvement_children(3) == FixedTaskChildren(
        (
            ChildAllocation("current-prompt", 20),
            ChildAllocation("draft-01", 20),
            ChildAllocation("draft-02", 20),
            ChildAllocation("draft-03", 20),
            ChildAllocation("reserved-checks", 20),
        )
    )


@pytest.mark.parametrize(
    ("proposals", "samples", "expected"),
    [
        (0, 5, ImprovementProposalLimitError(0, 1, 3)),
        (4, 5, ImprovementProposalLimitError(4, 1, 3)),
        (3, 0, ImprovementSampleLimitError(0, 1, 5)),
        (3, 6, ImprovementSampleLimitError(6, 1, 5)),
    ],
)
def test_the_search_is_bounded_to_three_drafts_and_five_samples(
    tmp_path: Path,
    proposals: int,
    samples: int,
    expected: Exception,
) -> None:
    request = ImprovementRequest(
        output=tmp_path / "results",
        fixtures=(),
        proposals=proposals,
        samples=samples,
    )

    with pytest.raises(type(expected)) as raised:
        validate_bounds(request)

    assert raised.value == expected


def test_application_factory_retains_authentication_for_the_complete_run(
    tmp_path: Path,
) -> None:
    current = replace(
        configuration(
            tmp_path,
            prompt_source(tmp_path / "sources", "prompt-source", "Original\n"),
            "current",
        ),
        isolation=IsolationConfiguration("darwin", "sandbox-exec"),
    )
    credentials = tmp_path / "claude-credentials.json"
    credentials.write_text(
        '{"claudeAiOauth":{'
        '"accessToken":"oauth-token",'
        '"refreshToken":"refresh-token",'
        '"expiresAt":9999999999999,'
        '"scopes":["user:inference"]'
        "}}"
    )
    codex_home = tmp_path / "codex"
    codex_home.mkdir()
    (codex_home / "auth.json").write_text('{"tokens":"credentials"}')
    store = ClaudeFileCredentialStore(
        credentials,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    cancellation = RunCancellation()
    codex = codex_identity(codex_home)
    codex.cancellation = cancellation
    authentication = RunAuthentication(
        claude=ClaudeOAuthIdentity(
            store.load(),
            store,
            AnthropicOAuthRefresher(
                current.claude.oauth_token_url,
                current.claude.oauth_client_id,
            ),
        ),
        codex=codex,
        codex_configuration=CodexHostConfiguration(()),
        cancellation=cancellation,
    )
    factory = ApplicationFactory(
        TaskScopes(RecordingRoots()),
        authentication,
        SlotPool(6),
    )
    credentials.unlink()

    applications = tuple(
        factory(current, events) for events in (RecordingEvents(), RecordingEvents())
    )

    assert (
        credentials.exists(),
        authentication.claude.access_token(),
        tuple(type(application) for application in applications),
    ) == (
        False,
        "oauth-token",
        (ProductionApplication, ProductionApplication),
    )


def test_platform_credentials_use_the_secure_storage_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current = configuration(
        tmp_path,
        prompt_source(tmp_path / "sources", "prompt-source", "Original\n"),
        "current",
    )
    configured = tmp_path / "configured"
    secure = tmp_path / "secure"
    secure.mkdir()
    credential = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "secure-token",
                    "refreshToken": "secure-refresh",
                    "expiresAt": 1_000,
                    "scopes": ["user:inference"],
                }
            }
        )
    )
    (secure / ".credentials.json").write_bytes(credential.encode())
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(configured))
    monkeypatch.setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", str(secure))

    store = platform_claude_credentials(current)
    loaded = store.load()
    unchanged = store.mutate(lambda value: value)

    assert (
        loaded,
        unchanged,
        configured.exists(),
        tuple(path.name for path in secure.iterdir()),
    ) == (
        credential,
        credential,
        False,
        (".credentials.json",),
    )


def test_the_tournament_selects_the_most_decisive_accepted_draft(
    tmp_path: Path,
) -> None:
    world = tournament(
        tmp_path,
        passes={
            "base-source": {"working": 0},
            "draft 1-source": {"working": 2},
            "draft 2-source": {"working": 5},
            "draft 3-source": {"working": 3},
        },
    )

    summary = world.run(proposals=3, samples=5)

    winner = world.output / "tries" / "winner.patch"
    expected = ImprovementSummary(
        accepted_proposals=2,
        attempted_proposals=3,
        reserved_checks_accepted=True,
        winner="draft-02",
        winner_patch=winner,
        reports=(
            draft_report(
                "draft-01",
                "draft 1",
                0,
                2,
                accepted=False,
                failures=(AcceptanceFailure.NOT_IMPROVED,),
            ),
            draft_report("draft-02", "draft 2", 0, 5, accepted=True),
            draft_report("draft-03", "draft 3", 0, 3, accepted=True),
        ),
    )
    assert (
        summary,
        decode_summary(world.output / "improvement-summary.json"),
        msgspec.json.decode(
            (world.output / "tries" / "draft-02" / "acceptance.json").read_bytes(),
            type=DraftReport,
        ),
        winner.read_text(),
        sorted(world.improver.angles) == sorted(IMPROVER_ANGLES),
        tuple(sorted(path.name for path in (world.output / "tries").iterdir())),
        improvement_completions(world.events),
    ) == (
        expected,
        expected,
        expected.reports[1],
        (
            "--- a/instructions/AGENTS.md\n"
            "+++ b/instructions/AGENTS.md\n"
            "@@ -1 +1 @@\n"
            "-Original\n"
            "+Draft 2\n"
        ),
        True,
        ("draft-01", "draft-02", "draft-03", "winner.patch"),
        (ImprovementFinished(2, 3, True, world.output, winner),),
    )


def test_every_arm_calibrates_its_first_sample_only(tmp_path: Path) -> None:
    world = tournament(
        tmp_path,
        passes={"base-source": {"working": 0}, "draft 1-source": {"working": 5}},
        proposals=(proposal(1),),
    )

    world.run(proposals=1, samples=3)

    assert sorted(world.script.evaluations) == [
        ("base-source", "current-prompt/sample-01", True),
        ("base-source", "current-prompt/sample-02", False),
        ("base-source", "current-prompt/sample-03", False),
        ("base-source", "reserved-checks/original/sample-01", True),
        ("base-source", "reserved-checks/original/sample-02", False),
        ("base-source", "reserved-checks/original/sample-03", False),
        ("draft 1-source", "reserved-checks/winning/sample-01", True),
        ("draft 1-source", "reserved-checks/winning/sample-02", False),
        ("draft 1-source", "reserved-checks/winning/sample-03", False),
        ("draft 1-source", "tries/draft-01/results/sample-01", True),
        ("draft 1-source", "tries/draft-01/results/sample-02", False),
        ("draft 1-source", "tries/draft-01/results/sample-03", False),
    ]


def test_the_reserved_original_prompt_is_measured_during_the_tournament(
    tmp_path: Path,
) -> None:
    started = Event()
    script = Script(
        passes={"base-source": {"working": 0}, "draft 1-source": {"working": 5}},
        started=started,
        started_prefix="reserved-checks/original",
    )
    world = tournament(
        tmp_path,
        script=script,
        proposals=(proposal(1),),
        improver=ScriptedImprover((proposal(1),), awaits=started),
    )

    summary = world.run(proposals=1, samples=3)

    assert (summary.winner, summary.reserved_checks_accepted) == ("draft-01", True)


def test_every_sample_of_one_evaluation_runs_at_the_same_time(
    tmp_path: Path,
) -> None:
    samples = 5
    world = tournament(
        tmp_path,
        script=Script(
            passes={"base-source": {"working": 0}},
            barrier=Barrier(samples, timeout=WAIT_SECONDS),
            barrier_prefix="current-prompt/",
        ),
        proposals=(no_change_proposal(),),
    )

    summary = world.run(proposals=1, samples=samples)

    assert (summary.attempted_proposals, summary.winner) == (0, None)


def test_every_draft_is_written_at_the_same_time(tmp_path: Path) -> None:
    proposals = tuple(proposal(index) for index in (1, 2, 3))
    world = tournament(
        tmp_path,
        passes={"base-source": {"working": 0}},
        proposals=proposals,
        improver=ScriptedImprover(
            proposals,
            barrier=Barrier(len(proposals), timeout=WAIT_SECONDS),
        ),
    )

    summary = world.run(proposals=3, samples=1)

    assert summary.attempted_proposals == 3


def test_concurrent_improver_runs_stay_within_the_run_slot_pool(
    tmp_path: Path,
) -> None:
    proposals = tuple(proposal(index) for index in (1, 2, 3))
    slots = RecordingSlots(capacity=2)
    world = tournament(
        tmp_path,
        passes={"base-source": {"working": 0}},
        proposals=proposals,
        improver=ScriptedImprover(
            proposals,
            barrier=Barrier(2, timeout=WAIT_SECONDS),
        ),
        slots=slots,
    )

    world.run(proposals=3, samples=1)

    assert (slots.peak, slots.held, slots.active) == (2, 3, 0)


def test_no_change_from_every_draft_leaves_no_winner(tmp_path: Path) -> None:
    world = tournament(
        tmp_path,
        passes={"base-source": {"working": 0}},
        proposals=(no_change_proposal(), no_change_proposal(), no_change_proposal()),
    )

    summary = world.run(proposals=3, samples=1)

    assert (
        summary,
        improvement_completions(world.events),
        sorted(world.script.evaluations),
        tuple(sorted(path.name for path in world.output.iterdir())),
        tuple(sorted(path.name for path in (world.output / "tries").iterdir())),
    ) == (
        ImprovementSummary(0, 0, False, None, None, ()),
        (ImprovementFinished(0, 0, False, world.output, None),),
        [
            ("base-source", "current-prompt/sample-01", True),
            ("base-source", "reserved-checks/original/sample-01", True),
        ],
        (
            ".claude-prompt-conformance",
            "current-prompt",
            "improvement-summary.json",
            "prompt-context.json",
            "reserved-checks",
            "run-metadata.json",
            "tries",
        ),
        ("draft-01", "draft-02", "draft-03"),
    )


def test_the_progress_tree_shows_drafts_and_samples_as_siblings(
    tmp_path: Path,
) -> None:
    world = tournament(
        tmp_path,
        passes={"base-source": {"working": 0}, "draft 1-source": {"working": 5}},
        proposals=(proposal(1),),
    )

    world.run(proposals=1, samples=3)

    assert task_outlines(world.roots) == (
        TaskOutline(
            path=("prompt-improvement",),
            kind=TaskKind.IMPROVEMENT,
            completed=3,
            total=3,
            outcome=TaskOutcome.PASSED,
            children=(
                evaluation_outline(
                    ("prompt-improvement",),
                    "current-prompt",
                    TaskOutcome.FAILED,
                    3,
                ),
                TaskOutline(
                    path=("prompt-improvement", "draft-01"),
                    kind=TaskKind.ITERATION,
                    completed=4,
                    total=4,
                    outcome=TaskOutcome.PASSED,
                    children=(
                        evaluation_outline(
                            ("prompt-improvement", "draft-01"),
                            "proposed-prompt",
                            TaskOutcome.PASSED,
                            3,
                        ),
                    ),
                ),
                TaskOutline(
                    path=("prompt-improvement", "reserved-checks"),
                    kind=TaskKind.EVALUATION,
                    completed=3,
                    total=3,
                    outcome=TaskOutcome.PASSED,
                    children=(
                        evaluation_outline(
                            ("prompt-improvement", "reserved-checks"),
                            "original-prompt",
                            TaskOutcome.PASSED,
                            3,
                        ),
                        evaluation_outline(
                            ("prompt-improvement", "reserved-checks"),
                            "winning-prompt",
                            TaskOutcome.PASSED,
                            3,
                        ),
                    ),
                ),
            ),
        ),
    )
    assert task_descriptions(world.roots) == (
        (("prompt-improvement",), "Prompt improvement"),
        (("prompt-improvement", "current-prompt"), "Test the current prompt"),
        *sample_descriptions(("prompt-improvement", "current-prompt"), 3),
        (("prompt-improvement", "draft-01"), "Draft 1: draft 1"),
        (
            ("prompt-improvement", "draft-01", "proposed-prompt"),
            "Test the proposed prompt",
        ),
        *sample_descriptions(("prompt-improvement", "draft-01", "proposed-prompt"), 3),
        (
            ("prompt-improvement", "reserved-checks"),
            "Check the winning prompt on reserved examples",
        ),
        (
            ("prompt-improvement", "reserved-checks", "original-prompt"),
            "Test the original prompt",
        ),
        *sample_descriptions(
            ("prompt-improvement", "reserved-checks", "original-prompt"), 3
        ),
        (
            ("prompt-improvement", "reserved-checks", "winning-prompt"),
            "Test the winning prompt",
        ),
        *sample_descriptions(
            ("prompt-improvement", "reserved-checks", "winning-prompt"), 3
        ),
    )


def sample_descriptions(
    parent: tuple[str, ...],
    samples: int,
) -> tuple[tuple[tuple[str, ...], str], ...]:
    """Project the sibling sample descriptions beneath one evaluation."""

    return tuple(
        ((*parent, f"sample-{sample:02}"), f"Sample {sample}")
        for sample in range(1, samples + 1)
    )


@pytest.mark.parametrize(
    ("uses", "expected"),
    [
        (
            (FixtureUse.RESERVED,),
            ImprovementWorkingExamplesEmptyError(),
        ),
        (
            (FixtureUse.WORKING,),
            ImprovementReservedChecksEmptyError(),
        ),
    ],
)
def test_prompt_improvement_requires_working_and_reserved_examples(
    tmp_path: Path,
    uses: tuple[FixtureUse, ...],
    expected: Exception,
) -> None:
    fixtures = tuple(
        replace(make_fixture(tmp_path / "fixtures", name=use.value), use=use)
        for use in uses
    )

    with pytest.raises(type(expected)) as raised:
        validate_fixture_sets(fixtures_by_use(fixtures))

    assert raised.value == expected


def test_sample_failure_cancels_concurrent_model_processes(tmp_path: Path) -> None:
    started = Event()
    cancellation = Event()
    marker = tmp_path / "sibling-cancelled"
    world = tournament(tmp_path, proposals=(no_change_proposal(),))

    def applications(
        current: RuntimeConfiguration,
        scoped_events: EventSink,
    ) -> Application:
        return Application(
            suite=CancellingSuite(
                current,
                world.events,
                world.script,
                started=started,
                cancellation=cancellation,
                marker=marker,
            ),
            improver=world.improver,
            variants=world.variants,
            instances=FakeInstances(),
            processes=CancellingProcesses(cancellation),
        )

    with pytest.raises(ImprovementEvidenceReadError) as raised:
        PromptImprovementSuite(
            applications,
            world.events,
            TaskScopes(world.roots),
            world.slots,
        ).run(
            world.original,
            ImprovementRequest(
                world.output,
                world.fixtures,
                proposals=1,
                samples=3,
            ),
        )

    assert (raised.value, marker.read_text()) == (
        ImprovementEvidenceReadError(
            world.output / "current-prompt" / "sample-02",
            errno.EIO,
        ),
        "cancelled\n",
    )


def test_invalid_evidence_cancels_the_rest_of_its_evaluation(tmp_path: Path) -> None:
    started = Event()
    cancellation = Event()
    marker = tmp_path / "sibling-cancelled"
    world = tournament(tmp_path, proposals=(no_change_proposal(),))

    def applications(
        current: RuntimeConfiguration,
        scoped_events: EventSink,
    ) -> Application:
        return Application(
            suite=UncalibratedSuite(
                current,
                world.events,
                world.script,
                started=started,
                cancellation=cancellation,
                marker=marker,
            ),
            improver=world.improver,
            variants=world.variants,
            instances=FakeInstances(),
            processes=CancellingProcesses(cancellation),
        )

    with pytest.raises(ImprovementCurrentPromptInvalidError) as raised:
        PromptImprovementSuite(
            applications,
            world.events,
            TaskScopes(world.roots),
            world.slots,
        ).run(
            world.original,
            ImprovementRequest(
                world.output,
                world.fixtures,
                proposals=1,
                samples=3,
            ),
        )

    assert (raised.value, marker.read_text()) == (
        ImprovementCurrentPromptInvalidError(),
        "cancelled\n",
    )


def test_a_cancelled_sibling_does_not_mask_invalid_evidence(tmp_path: Path) -> None:
    started = Event()
    cancellation = Event()
    world = tournament(tmp_path, proposals=(no_change_proposal(),))

    def applications(
        current: RuntimeConfiguration,
        scoped_events: EventSink,
    ) -> Application:
        return Application(
            suite=UncalibratedRaisingSuite(
                current,
                world.events,
                world.script,
                started=started,
                cancellation=cancellation,
            ),
            improver=world.improver,
            variants=world.variants,
            instances=FakeInstances(),
            processes=CancellingProcesses(cancellation),
        )

    with pytest.raises(ImprovementCurrentPromptInvalidError):
        PromptImprovementSuite(
            applications,
            world.events,
            TaskScopes(world.roots),
            world.slots,
        ).run(
            world.original,
            ImprovementRequest(
                world.output,
                world.fixtures,
                proposals=1,
                samples=3,
            ),
        )


@pytest.mark.parametrize(
    ("drafts", "expected"),
    [
        pytest.param(((1, 3, 0), (2, 5, 0), (3, 4, 0)), "draft-02", id="most-decisive"),
        pytest.param(((1, 4, 1), (2, 4, 0), (3, 3, 0)), "draft-02", id="least-noise"),
        pytest.param(((1, 4, 1), (2, 4, 1), (3, 9, 9)), "draft-01", id="lowest-index"),
    ],
)
def test_the_winner_is_the_most_decisive_accepted_draft(
    drafts: tuple[tuple[int, int, int], ...],
    expected: str,
) -> None:
    accepted = tuple(
        accepted_draft(index, improvement, noise, accepted=index != 3)
        for index, improvement, noise in drafts
    )

    winner = winning_draft(accepted)

    assert winner is not None and winner.identifier == expected


def test_no_accepted_draft_has_no_winner() -> None:
    drafts = (
        accepted_draft(1, 5, 0, accepted=False),
        DraftOutcome(2, "draft-02", no_change_proposal(), None, None),
    )

    assert winning_draft(drafts) is None


def accepted_draft(
    index: int,
    improvement: int,
    noise: int,
    *,
    accepted: bool,
) -> DraftOutcome:
    """Build one finished draft whose acceptance report is already known."""

    return DraftOutcome(
        index=index,
        identifier=f"draft-{index:02}",
        proposal=proposal(index),
        configuration=None,
        report=DraftReport(
            draft=f"draft-{index:02}",
            title=f"draft {index}",
            acceptance=AcceptanceReport(
                accepted=accepted,
                failures=() if accepted else (AcceptanceFailure.NOT_IMPROVED,),
                comparisons=(),
                decisive_improvement=improvement,
                noise_regressions=noise,
            ),
        ),
    )


@dataclass(frozen=True)
class Arm:
    """One prompt evaluation described by its per-fixture pass counts."""

    passes: dict[str, int]
    gate: GateOutcome = GateOutcome.PASSED


@dataclass(frozen=True)
class Decision:
    """The acceptance outcome a comparison is required to reach."""

    accepted: bool
    failures: tuple[AcceptanceFailure, ...]
    decisive_improvement: int
    noise_regressions: int


SAMPLES = 5


def evaluation(
    root: Path,
    fixtures: tuple[Fixture, ...],
    arm: Arm,
    *,
    samples: int = SAMPLES,
) -> tuple[RunSummary, ...]:
    """Build one evaluation's samples from per-fixture criterion pass counts."""

    return tuple(
        arm_summary(root / f"sample-{sample:02}", fixtures, arm, sample)
        for sample in range(1, samples + 1)
    )


def arm_summary(
    artefacts: Path,
    fixtures: tuple[Fixture, ...],
    arm: Arm,
    sample: int,
) -> RunSummary:
    """Build one sample in which the earliest samples carry the passes."""

    runs = tuple(
        arm_run(
            artefacts / fixture.name,
            fixture,
            sample <= arm.passes[fixture.name],
            arm.gate,
        )
        for fixture in fixtures
    )
    return RunSummary(
        passed=sum(run.status is Status.PASSED for run in runs),
        failed=sum(run.status is Status.FAILED for run in runs),
        invalid=0,
        stale=0,
        results=runs,
    )


def arm_run(
    artefacts: Path,
    fixture: Fixture,
    criterion_passed: bool,
    gate: GateOutcome,
) -> FixtureRun:
    """Build one fixture outcome carrying a criterion verdict and gate result."""

    artefacts.mkdir(parents=True)
    result = Result(
        CandidateResult(
            "Completed.",
            artefacts / "transcript.jsonl",
            artefacts / "actions.json",
        ),
        workspace_evidence("base", "head", artefacts),
        verification_results(
            "head",
            artefacts,
            return_code=1 if gate is GateOutcome.FAILED else 0,
            flaky=gate is GateOutcome.QUARANTINED,
        ),
        judgement(criterion_passed, "head"),
        (),
    )
    passed = criterion_passed and gate is not GateOutcome.FAILED
    status = Status.PASSED if passed else Status.FAILED
    return FixtureRun(
        fixture,
        status,
        artefacts,
        () if passed else ("failed",),
        result,
        None,
    )


def comparison_fixtures(root: Path) -> tuple[Fixture, ...]:
    """Build two independent working examples, each with one criterion."""

    return tuple(
        replace(make_fixture(root, name=name), use=FixtureUse.WORKING)
        for name in ("alpha", "beta")
    )


def decision(report: AcceptanceReport) -> Decision:
    """Project the decision a comparison reached, without its evidence."""

    return Decision(
        report.accepted,
        report.failures,
        report.decisive_improvement,
        report.noise_regressions,
    )


@pytest.mark.parametrize(
    ("baseline", "proposed", "expected"),
    [
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 3, "beta": 5}),
            Decision(True, (), 3, 0),
            id="decisive-gain",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 2, "beta": 5}),
            Decision(False, (AcceptanceFailure.NOT_IMPROVED,), 0, 0),
            id="gain-below-threshold",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 3, "beta": 4}),
            Decision(True, (), 3, 1),
            id="noise-regression-tolerated",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 3, "beta": 3}),
            Decision(False, (AcceptanceFailure.REGRESSION,), 3, 0),
            id="regression-beyond-noise",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 5, "beta": 5}),
            Decision(False, (AcceptanceFailure.NOT_IMPROVED,), 0, 0),
            id="no-movement",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 0}),
            Arm({"alpha": 0, "beta": 0}),
            Decision(False, (AcceptanceFailure.NOT_IMPROVED,), 0, 0),
            id="no-movement-while-failing",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 5, "beta": 5}),
            Decision(True, (), 5, 0),
            id="complete-repair",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 3, "beta": 5}, GateOutcome.QUARANTINED),
            Decision(True, (), 3, 0),
            id="quarantined-gate-excluded",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}),
            Arm({"alpha": 3, "beta": 5}, GateOutcome.FAILED),
            Decision(False, (AcceptanceFailure.GATE_FAILURE,), 3, 0),
            id="repeated-gate-failure",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}, GateOutcome.FAILED),
            Arm({"alpha": 3, "beta": 5}, GateOutcome.FAILED),
            Decision(True, (), 3, 0),
            id="pre-existing-gate-failure-forgiven",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 5}, GateOutcome.FAILED),
            Arm({"alpha": 0, "beta": 5}),
            Decision(True, (), 0, 0),
            id="repaired-gate-without-criterion-movement",
        ),
    ],
)
def test_acceptance_requires_a_decisive_gain_without_a_regression(
    tmp_path: Path,
    baseline: Arm,
    proposed: Arm,
    expected: Decision,
) -> None:
    fixtures = comparison_fixtures(tmp_path / "fixtures")

    report = compare_results(
        evaluation(tmp_path / "current", fixtures, baseline),
        evaluation(tmp_path / "proposed", fixtures, proposed),
    )

    assert decision(report) == expected


def test_acceptance_reports_both_sides_the_net_change_and_flakiness(
    tmp_path: Path,
) -> None:
    fixtures = comparison_fixtures(tmp_path / "fixtures")

    report = compare_results(
        evaluation(tmp_path / "current", fixtures, Arm({"alpha": 1, "beta": 5})),
        evaluation(tmp_path / "proposed", fixtures, Arm({"alpha": 4, "beta": 4})),
    )

    assert report == AcceptanceReport(
        accepted=True,
        failures=(),
        comparisons=(
            CriterionComparison(
                fixture="alpha",
                criterion="works",
                baseline_passed=1,
                baseline_total=5,
                proposed_passed=4,
                proposed_total=5,
                change=3,
                flaky=True,
            ),
            CriterionComparison(
                fixture="beta",
                criterion="works",
                baseline_passed=5,
                baseline_total=5,
                proposed_passed=4,
                proposed_total=5,
                change=-1,
                flaky=False,
            ),
        ),
        decisive_improvement=3,
        noise_regressions=1,
    )


def test_incomplete_proposed_evidence_cannot_be_accepted(tmp_path: Path) -> None:
    fixtures = comparison_fixtures(tmp_path / "fixtures")
    current = evaluation(tmp_path / "current", fixtures, Arm({"alpha": 0, "beta": 5}))
    proposed = evaluation(tmp_path / "proposed", fixtures, Arm({"alpha": 5, "beta": 5}))
    first, *rest = proposed

    report = compare_results(
        current,
        (replace(first, passed=0, invalid=2, results=()), *rest),
    )

    assert decision(report) == Decision(
        False,
        (AcceptanceFailure.INVALID_EVIDENCE,),
        4,
        1,
    )


def test_stale_retained_state_is_not_complete_improvement_evidence(
    tmp_path: Path,
) -> None:
    fixtures = comparison_fixtures(tmp_path / "fixtures")
    complete = evaluation(tmp_path / "complete", fixtures, Arm({"alpha": 5, "beta": 5}))
    first, *rest = complete
    stale = (replace(first, passed=0, stale=2, results=()), *rest)

    assert (
        summaries_have_complete_evidence(complete),
        summaries_have_complete_evidence(stale),
        reserved_results_accepted(complete, stale),
    ) == (True, False, False)


@pytest.mark.parametrize(
    ("original", "winning", "expected"),
    [
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 5, "beta": 5}),
            True,
            id="unchanged",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 4, "beta": 5}),
            True,
            id="noise-regression-tolerated",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 3, "beta": 5}),
            False,
            id="regression-beyond-noise",
        ),
        pytest.param(
            Arm({"alpha": 0, "beta": 0}),
            Arm({"alpha": 5, "beta": 5}),
            True,
            id="improvement-is-not-required",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 5, "beta": 5}, GateOutcome.FAILED),
            False,
            id="new-gate-failure",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}, GateOutcome.FAILED),
            Arm({"alpha": 5, "beta": 5}, GateOutcome.FAILED),
            True,
            id="pre-existing-gate-failure-forgiven",
        ),
        pytest.param(
            Arm({"alpha": 5, "beta": 5}),
            Arm({"alpha": 5, "beta": 5}, GateOutcome.QUARANTINED),
            True,
            id="quarantined-gate-excluded",
        ),
    ],
)
def test_reserved_checks_require_non_inferiority(
    tmp_path: Path,
    original: Arm,
    winning: Arm,
    expected: bool,
) -> None:
    fixtures = tuple(
        replace(fixture, use=FixtureUse.RESERVED)
        for fixture in comparison_fixtures(tmp_path / "fixtures")
    )

    accepted = reserved_results_accepted(
        evaluation(tmp_path / "original", fixtures, original),
        evaluation(tmp_path / "winning", fixtures, winning),
    )

    assert accepted is expected


def test_bounded_evidence_limits_binary_check_output(tmp_path: Path) -> None:
    evidence = tmp_path / "check.stdout"
    evidence.write_bytes(b"abc\xffmore")

    assert bounded_evidence(evidence, 4) == ("abc�", True)


def test_bounded_evidence_reports_read_failures_as_typed_errors(
    tmp_path: Path,
) -> None:
    with pytest.raises(ImprovementEvidenceReadError) as raised:
        bounded_evidence(tmp_path, 4)

    assert raised.value == ImprovementEvidenceReadError(tmp_path, errno.EISDIR)


def evaluation_outline(
    parent: tuple[str, ...],
    name: str,
    outcome: TaskOutcome = TaskOutcome.FAILED,
    samples: int = 1,
) -> TaskOutline:
    """Project one evaluation and its concurrent samples beneath its parent."""

    path = (*parent, name)
    return TaskOutline(
        path=path,
        kind=TaskKind.EVALUATION,
        completed=samples,
        total=samples,
        outcome=outcome,
        children=tuple(
            TaskOutline(
                path=(*path, f"sample-{sample:02}"),
                kind=TaskKind.SAMPLE,
                completed=0,
                total=0,
                outcome=outcome,
                children=(),
            )
            for sample in range(1, samples + 1)
        ),
    )


def prompt_tree(root: Path, files: dict[str, str]) -> Path:
    """Materialise one controlled prompt source tree from relative documents."""

    for directory in ("instructions", "output-style"):
        (root / directory).mkdir(parents=True)
    for name, text in files.items():
        (root / name).write_text(text)
    return root


@pytest.mark.parametrize(
    ("base_files", "variant_files", "expected"),
    [
        (
            {},
            {"instructions/new.md": "Added\n"},
            (
                "--- a/instructions/new.md\n"
                "+++ b/instructions/new.md\n"
                "@@ -0,0 +1 @@\n"
                "+Added\n"
            ),
        ),
        (
            {"instructions/gone.md": "Removed\n"},
            {},
            (
                "--- a/instructions/gone.md\n"
                "+++ b/instructions/gone.md\n"
                "@@ -1 +0,0 @@\n"
                "-Removed\n"
            ),
        ),
        (
            {"instructions/settings.json": '{"style": "plain"}\n'},
            {"instructions/settings.json": '{"style": "technical"}\n'},
            (
                "--- a/instructions/settings.json\n"
                "+++ b/instructions/settings.json\n"
                "@@ -1 +1 @@\n"
                '-{"style": "plain"}\n'
                '+{"style": "technical"}\n'
            ),
        ),
        (
            {"output-style/plain.md": "Old"},
            {"output-style/plain.md": "New"},
            (
                "--- a/output-style/plain.md\n"
                "+++ b/output-style/plain.md\n"
                "@@ -1 +1 @@\n"
                "-Old\n"
                "\\ No newline at end of file\n"
                "+New\n"
                "\\ No newline at end of file\n"
            ),
        ),
        (
            {"instructions/AGENTS.md": "One\n", "output-style/plain.md": "Two"},
            {"instructions/AGENTS.md": "One!\n", "output-style/plain.md": "Two!"},
            (
                "--- a/instructions/AGENTS.md\n"
                "+++ b/instructions/AGENTS.md\n"
                "@@ -1 +1 @@\n"
                "-One\n"
                "+One!\n"
                "--- a/output-style/plain.md\n"
                "+++ b/output-style/plain.md\n"
                "@@ -1 +1 @@\n"
                "-Two\n"
                "\\ No newline at end of file\n"
                "+Two!\n"
                "\\ No newline at end of file\n"
            ),
        ),
    ],
)
def test_winner_patch_describes_every_eligible_prompt_change(
    tmp_path: Path,
    base_files: dict[str, str],
    variant_files: dict[str, str],
    expected: str,
) -> None:
    base = prompt_tree(tmp_path / "base", base_files)
    variant = prompt_tree(tmp_path / "variant", variant_files)

    assert prompt_tree_diff(base, variant) == expected


def improvement_completions(
    events: RecordingEvents,
) -> tuple[ImprovementFinished, ...]:
    """Project complete search results from the frontend event stream."""

    completions: list[ImprovementFinished] = []
    for event in events.events:
        match event:
            case ImprovementFinished():
                completions.append(event)
            case _:
                continue
    return tuple(completions)


def task_descriptions(
    roots: RecordingRoots,
) -> tuple[tuple[tuple[str, ...], str], ...]:
    """Project descriptions in deterministic tree order."""

    def descendants(task: TaskRun) -> tuple[tuple[tuple[str, ...], str], ...]:
        snapshot = task.snapshot()
        return (
            (snapshot.path, snapshot.description),
            *(item for child in task.children for item in descendants(child)),
        )

    return tuple(item for root in roots.roots for item in descendants(root))
