import base64
import json
import shutil
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from threading import Lock, Semaphore
from types import TracebackType

import httpx

from claude_prompt_conformance.codex_identity import (
    CodexFileCredentialStore,
    CodexHostIdentity,
    CodexOAuthRefresher,
)
from claude_prompt_conformance.credential_lock import (
    CredentialLockCompromisedError,
    CredentialLockReleaseError,
    CredentialLockUpdateError,
)
from claude_prompt_conformance.models import (
    CalibrationCandidate,
    CandidateResult,
    Criterion,
    CriterionKind,
    Event,
    FailureOrigin,
    Fixture,
    FixtureUse,
    InstancePaths,
    JudgedCriterion,
    Judgement,
    JudgementSubject,
    RepositorySpec,
    TaskKind,
    VerificationCommand,
    VerificationKind,
    VerificationResult,
    WorkspaceEvidence,
)
from claude_prompt_conformance.ports import ActivityReporter
from claude_prompt_conformance.progress import TaskKind as ProgressTaskKind
from claude_prompt_conformance.progress import TaskOutcome, TaskRun


def unsigned_access_token() -> str:
    """Build the unsigned JWT shape the pinned Codex accepts as external auth."""

    header = {"alg": "none", "typ": "JWT"}
    payload = {
        "email": "judge@example.invalid",
        "https://api.openai.com/auth": {
            "chatgpt_plan_type": "pro",
            "chatgpt_account_id": "account-1",
        },
    }

    def encode(value: object) -> str:
        encoded = base64.urlsafe_b64encode(
            json.dumps(value, separators=(",", ":")).encode()
        )
        return encoded.rstrip(b"=").decode()

    return f"{encode(header)}.{encode(payload)}.{encode('signature')}"


def codex_refresh_transport(access_token: str) -> httpx.MockTransport:
    """Answer every OAuth refresh with the same subscription tokens."""

    def respond(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "id_token": "header.payload.signature",
                "access_token": access_token,
                "refresh_token": "refresh-token",
            },
        )

    return httpx.MockTransport(respond)


def codex_identity(
    codex_home: Path,
    access_token: str = "access-token",
    account_id: str = "account-id",
    transport: httpx.MockTransport | None = None,
) -> CodexHostIdentity:
    """Create a normal subscription login and its run-scoped broker."""

    codex_home.mkdir(parents=True, exist_ok=True)
    (codex_home / "auth.json").write_text(
        json.dumps(
            {
                "tokens": {
                    "id_token": "header.payload.signature",
                    "access_token": access_token,
                    "refresh_token": "refresh-token",
                    "account_id": account_id,
                },
                "last_refresh": "2026-08-13T00:00:00Z",
            }
        )
    )
    store = CodexFileCredentialStore(codex_home / "auth.json")
    return CodexHostIdentity(
        store,
        CodexOAuthRefresher(
            "https://codex.invalid/oauth/token",
            "codex-client",
            transport=transport
            if transport is not None
            else httpx.MockTransport(lambda _: httpx.Response(500)),
        ),
        store.load(),
    )


@dataclass
class RecordingEvents:
    events: list[Event] = field(default_factory=list)

    def emit(self, event: Event) -> None:
        self.events.append(event)


@dataclass
class RecordingRoots:
    roots: list[TaskRun] = field(default_factory=list)

    def observe(self, root: TaskRun) -> None:
        self.roots.append(root)


@dataclass(frozen=True)
class ExitFailingLock:
    """Credential lock fake which fails only after a successful body."""

    error: (
        CredentialLockCompromisedError
        | CredentialLockReleaseError
        | CredentialLockUpdateError
    )

    def __enter__(self) -> None:
        pass

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        raise self.error

    def check(self) -> None:
        pass


@dataclass(frozen=True)
class TaskOutline:
    """A deterministic projection of a live task tree for structural tests."""

    path: tuple[str, ...]
    kind: ProgressTaskKind
    completed: int
    total: int | None
    outcome: TaskOutcome | None
    children: tuple["TaskOutline", ...]


def task_outlines(roots: RecordingRoots) -> tuple[TaskOutline, ...]:
    """Project every observed root and its complete descendants."""

    return tuple(task_outline(root) for root in roots.roots)


def task_outline(task: TaskRun) -> TaskOutline:
    """Project one task using the state relevant to orchestration tests."""

    snapshot = task.snapshot()
    return TaskOutline(
        path=snapshot.path,
        kind=snapshot.kind,
        completed=snapshot.completed,
        total=snapshot.total,
        outcome=snapshot.outcome,
        children=tuple(task_outline(child) for child in task.children),
    )


class FakeProcesses:
    def cancel(self) -> None:
        pass


@dataclass
class RecordingSlots:
    """Bound agent processes while recording the concurrency actually reached."""

    capacity: int = 8
    active: int = 0
    peak: int = 0
    held: int = 0
    _lock: Lock = field(default_factory=Lock)
    _released: Semaphore | None = None

    def __post_init__(self) -> None:
        self._released = Semaphore(self.capacity)

    @contextmanager
    def hold(self) -> Iterator[None]:
        assert self._released is not None
        self._released.acquire()
        with self._lock:
            self.active += 1
            self.held += 1
            self.peak = max(self.peak, self.active)
        try:
            yield
        finally:
            with self._lock:
                self.active -= 1
            self._released.release()


class FakeInstances:
    def create(self, name: str, results: Path) -> InstancePaths:
        paths = instance_paths(name, results)
        for path in paths.__dict__.values():
            path.mkdir(parents=True, exist_ok=True)
        return paths

    def clean(self, instance: InstancePaths) -> None:
        shutil.rmtree(instance.root)


def instance_paths(name: str, results: Path) -> InstancePaths:
    root = results / name
    return InstancePaths(
        root=root,
        workspace=root / "workspace",
        control=root / "control",
        candidate_state=root / "candidate-state",
        candidate_cache=root / "candidate-cache",
        candidate_temp=root / "candidate-temp",
        judge_state=root / "judge-state",
        judge_cache=root / "judge-cache",
        judge_temp=root / "judge-temp",
    )


class FakeRepositories:
    def materialise(
        self,
        repository: RepositorySpec,
        destination: Path,
        control: Path,
        environment_path: str,
        comparison_revision: str,
    ) -> None:
        (destination / "repository.json").write_text(
            json.dumps(
                {
                    "comparisonRevision": comparison_revision,
                    "environmentPath": environment_path,
                    "repository": {
                        "revision": repository.revision,
                        "url": repository.url,
                    },
                },
                sort_keys=True,
            )
        )
        (control / "materialised").write_text("ready\n")


class FakeOverlay:
    def install(self, workspace: Path) -> None:
        repository = json.loads((workspace / "repository.json").read_text())
        (workspace / "overlay.json").write_text(
            json.dumps({"repository": repository, "status": "installed"})
        )


class FakePreparer:
    def prepare(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> None:
        (instance.control / "prepared").write_text(f"{fixture.name}\n")
        (artefacts / "preparation.txt").write_text(f"{fixture.name}\n")


class FakeCandidate:
    def run(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
        activity: ActivityReporter,
    ) -> CandidateResult:
        repository = json.loads((instance.workspace / "repository.json").read_text())
        overlay = json.loads((instance.workspace / "overlay.json").read_text())
        expected_repository = {
            "comparisonRevision": fixture.comparison_revision,
            "environmentPath": fixture.environment_path,
            "repository": {
                "revision": fixture.repository.revision,
                "url": fixture.repository.url,
            },
        }
        if repository != expected_repository:
            raise ValueError("candidate repository is not the requested checkout")
        if overlay != {"repository": repository, "status": "installed"}:
            raise ValueError("candidate prompt overlay is incomplete")

        transcript = artefacts / "transcript.jsonl"
        trace = artefacts / "trace.jsonl"
        transcript.write_text("{}\n")
        trace.write_text("{}\n")
        return candidate_result(artefacts)


class FakeInspector:
    def inspect(
        self,
        workspace: Path,
        base_revision: str,
        artefacts: Path,
        environment_path: str,
    ) -> WorkspaceEvidence:
        repository = json.loads((workspace / "repository.json").read_text())
        if repository["comparisonRevision"] != base_revision:
            raise ValueError("repository comparison revision is inconsistent")
        if repository["environmentPath"] != environment_path:
            raise ValueError("repository environment is inconsistent")

        head_revision = repository["repository"]["revision"]
        diff = artefacts / "diff.patch"
        commits = artefacts / "commits.txt"
        snapshot = artefacts / "workspace-snapshot"
        snapshot.mkdir()
        (snapshot / "file").write_text(f"contents at {head_revision}\n")
        diff.write_text(f"diff for {head_revision}\n")
        commits.write_text(f"commit {head_revision}\n")
        return workspace_evidence(base_revision, head_revision, artefacts)


class FakeVerifier:
    def verify(
        self, fixture: Fixture, instance: InstancePaths, artefacts: Path
    ) -> tuple[VerificationResult, ...]:
        overlay = json.loads((instance.workspace / "overlay.json").read_text())
        repository = overlay["repository"]
        if overlay["status"] != "installed":
            raise ValueError("prompt overlay is incomplete")
        if repository["environmentPath"] != fixture.environment_path:
            raise ValueError("verification environment is inconsistent")

        revision = repository["repository"]["revision"]
        stdout = artefacts / "check.stdout"
        stderr = artefacts / "check.stderr"
        stdout.write_text(f"verified {revision}\n")
        stderr.write_text("")
        return verification_results(revision, artefacts)


class FakeJudge:
    def assess(
        self,
        fixture: Fixture,
        subject: JudgementSubject,
        instance: InstancePaths,
        artefacts: Path,
    ) -> Judgement:
        passed = subject.name == "candidate" or subject.evidence.head_revision != "base"
        return judgement(passed, subject.evidence.head_revision)


def judgement(passed: bool, revision: str) -> Judgement:
    return Judgement(
        criteria=(
            JudgedCriterion(
                identifier="works",
                passed=passed,
                reason="assessment",
                evidence=(revision,),
            ),
        ),
        failure_origin=FailureOrigin.NONE if passed else FailureOrigin.CANDIDATE,
        summary="assessment",
        recommendation="No changes are needed." if passed else "Apply the fix.",
        counterfactual="" if passed else "diff --git a/file b/file",
        corrected_response="" if passed else "Fixed and checked.",
        prompt_observations=(),
    )


def candidate_result(artefacts: Path) -> CandidateResult:
    return CandidateResult(
        "candidate response",
        artefacts / "transcript.jsonl",
        artefacts / "trace.jsonl",
    )


def workspace_evidence(
    base_revision: str, head_revision: str, artefacts: Path
) -> WorkspaceEvidence:
    return WorkspaceEvidence(
        workspace=artefacts / "workspace-snapshot",
        base_revision=base_revision,
        head_revision=head_revision,
        status=" M file",
        diff=artefacts / "diff.patch",
        commits=artefacts / "commits.txt",
        changed_files=("file",),
    )


def verification_results(
    revision: str,
    artefacts: Path,
    *,
    return_code: int = 0,
    kind: VerificationKind = VerificationKind.GATE,
    flaky: bool = False,
) -> tuple[VerificationResult, ...]:
    return (
        VerificationResult(
            "check",
            ("check",),
            kind,
            0,
            return_code,
            artefacts / "check.stdout",
            artefacts / "check.stderr",
            flaky,
        ),
    )


def make_fixture(
    root: Path,
    *,
    name: str = "example",
    description: str = "Investigate a representative repository failure.",
    category: str = "repository-change",
    tags: tuple[str, ...] = ("shell",),
    comparison_revision: str = "base",
    environment_path: str = "/bin",
) -> Fixture:
    path = root / name
    path.mkdir(parents=True)
    task = path / "task.txt"
    task.write_text("Investigate and fix the failure.")
    known_good = path / "known-good.txt"
    unchanged = path / "unchanged.txt"
    known_good.write_text("Fixed and checked.")
    unchanged.write_text("No change needed.")
    base = RepositorySpec("https://example.invalid/repository.git", "base")
    return Fixture(
        name=name,
        description=description,
        kind=TaskKind.AUTHOR,
        use=FixtureUse.WORKING,
        category=category,
        tags=tags,
        path=path,
        task=task,
        repository=base,
        comparison_revision=comparison_revision,
        environment_path=environment_path,
        criteria=(Criterion("works", CriterionKind.OUTCOME, "The fix works.", True),),
        verification=(
            VerificationCommand("check", ("check",), VerificationKind.GATE, 0, "."),
        ),
        calibration=(
            CalibrationCandidate(
                "known-good",
                RepositorySpec(base.url, "good"),
                known_good,
                (("works", True),),
            ),
            CalibrationCandidate(
                "unchanged-base", base, unchanged, (("works", False),)
            ),
        ),
    )
