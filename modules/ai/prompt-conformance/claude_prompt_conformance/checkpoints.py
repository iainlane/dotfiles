"""Typed, durable fixture checkpoints used for automatic run resumption."""

import hashlib
import os
import stat
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Protocol, TypeVar

import msgspec

from .errors import ConformanceError, RetainedStateError
from .models import (
    CalibrationAssessment,
    EvidenceDigest,
    Fixture,
    FixtureCheckpoint,
    JudgementSubject,
    RetainedCalibration,
    TestResult,
)
from .storage import (
    STATE_DIRECTORY,
    RetainedPathUnsafeError,
    atomic_write,
    clear_directory,
    directory_exists,
    pending_files,
)


@dataclass(eq=True)
class FixtureEvidenceReadError(RetainedStateError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read retained fixture evidence {self.source}: {self.cause}"


@dataclass(eq=True)
class FixtureEvidenceMismatchError(RetainedStateError):
    source: Path

    def __str__(self) -> str:
        return f"retained fixture evidence does not match its checkpoint: {self.source}"


@dataclass(eq=True)
class FixtureCheckpointReadError(RetainedStateError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read fixture checkpoint {self.source}: {self.cause}"


@dataclass(eq=True)
class FixtureCheckpointDecodeError(RetainedStateError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError | ValueError

    def __str__(self) -> str:
        return f"fixture checkpoint {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class FixtureCheckpointEvidenceReadError(RetainedStateError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read evidence referenced by fixture checkpoint {self.source}: {self.cause}"


@dataclass(eq=True)
class FixtureCheckpointMismatchError(RetainedStateError):
    source: Path
    fixture: str

    def __str__(self) -> str:
        return (
            f"fixture checkpoint {self.source} does not describe "
            f"the selected test {self.fixture!r}"
        )


@dataclass(eq=True)
class FixtureCheckpointWriteError(RetainedStateError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain fixture checkpoint {self.destination}: {self.cause}"


@dataclass(eq=True)
class FixtureAttemptResetError(RetainedStateError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not reset incomplete fixture attempt {self.path}: {self.cause}"


@dataclass(eq=True)
class RunMetadataDecodeError(ConformanceError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"run metadata {self.source} is not a JSON document: {self.cause}"


@dataclass(frozen=True)
class StoredTestResult:
    """Terminal result plus the durable evidence identity it was judged against."""

    result: TestResult
    contract: str
    evidence: tuple[EvidenceDigest, ...]


@dataclass(frozen=True)
class StoredCalibration:
    """Reference judgements plus the identity which produced and supports them.

    The judgements are shared by every arm of one run store, so they name the
    fixture attempt whose retained evidence supports them as a path relative to
    the store root.
    """

    assessments: tuple[CalibrationAssessment, ...]
    contract: str
    judge: str
    evidence: tuple[EvidenceDigest, ...]
    artefacts: str


CHECKPOINT_FILE = Path(STATE_DIRECTORY) / "checkpoint.json"
RESULT_FILE = Path(STATE_DIRECTORY) / "result.json"
CALIBRATION_STATE = Path(STATE_DIRECTORY) / "calibration"
CALIBRATION_DIRECTORY = "calibration"
RETAINED_CALIBRATION = frozenset({CALIBRATION_DIRECTORY})
CANDIDATE_PROMPT_MEMBERS = frozenset({"defaultOutputStyle", "outputStyles", "prompt"})

StoredValue = FixtureCheckpoint | StoredTestResult | StoredCalibration
LoadedValue = FixtureCheckpoint | TestResult
CalibrationVerdicts = tuple[tuple[str, tuple[tuple[str, bool], ...]], ...]
T = TypeVar("T", bound=StoredValue)


class DigestWriter(Protocol):
    """The hash operation needed while constructing fixture contracts."""

    def update(self, contents: bytes, /) -> None: ...


class JsonFixtureResultStore:
    """Store phase outcomes as schema-decoded JSON beside their evidence."""

    def load(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        *,
        calibrate: bool,
    ) -> LoadedValue | None:
        if not directory_exists(root, artefacts):
            return None
        stored_result = self._read(
            artefacts,
            artefacts / RESULT_FILE,
            StoredTestResult,
            recover_interrupted=True,
        )
        if stored_result is not None:
            self._validate_result(
                fixture,
                stored_result.result,
                artefacts / RESULT_FILE,
                calibrate,
                stored_result.contract,
            )
            validate_evidence(
                result_checkpoint(stored_result.result),
                stored_result.evidence,
                artefacts,
                artefacts / RESULT_FILE,
            )
            return stored_result.result

        checkpoint = self._read(
            artefacts,
            artefacts / CHECKPOINT_FILE,
            FixtureCheckpoint,
            recover_interrupted=True,
        )
        if checkpoint is not None:
            self._validate_checkpoint(
                fixture,
                checkpoint,
                artefacts / CHECKPOINT_FILE,
                calibrate,
            )
            validate_evidence(
                checkpoint,
                checkpoint.evidence,
                artefacts,
                artefacts / CHECKPOINT_FILE,
            )
            return checkpoint

        return None

    def load_calibration(
        self,
        root: Path,
        fixture: Fixture,
        *,
        judge: str,
    ) -> RetainedCalibration | None:
        """Recover calibration any arm of this run store completed for this judge."""

        source = calibration_state(root, fixture)
        # An arm racing this one may be part way through publishing the same
        # judgements, so an interrupted write is never adopted here: its author
        # is more probably alive than crashed, and recalibrating is safe.
        stored = self._read(root, source, StoredCalibration, recover_interrupted=False)
        if stored is None:
            return None

        if (
            stored.contract != fixture_contract(fixture)
            or stored.judge != judge
            or calibration_verdicts(stored.assessments)
            != calibration_declaration(fixture)
        ):
            raise FixtureCheckpointMismatchError(source, fixture.name)

        artefacts = calibration_evidence_root(root, stored.artefacts)
        if not directory_exists(root, artefacts):
            raise FixtureEvidenceMismatchError(source)
        if calibration_inventory(artefacts) != stored.evidence:
            raise FixtureEvidenceMismatchError(source)
        return RetainedCalibration(stored.assessments, artefacts)

    def reset(
        self,
        root: Path,
        artefacts: Path,
        *,
        retain_calibration: bool = False,
    ) -> None:
        """Remove an incomplete fixture attempt before starting it again."""

        retained = RETAINED_CALIBRATION if retain_calibration else frozenset()
        try:
            clear_directory(root, artefacts, retained)
        except OSError as error:
            raise FixtureAttemptResetError(artefacts, error) from error

    def save_calibration(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        calibration: tuple[CalibrationAssessment, ...],
        *,
        judge: str,
    ) -> None:
        """Publish judgements every arm of this run store may reuse."""

        self._write(
            root,
            root,
            calibration_state(root, fixture),
            StoredCalibration(
                calibration,
                fixture_contract(fixture),
                judge,
                calibration_inventory(artefacts),
                store_relative(root, artefacts),
            ),
        )

    def save_checkpoint(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        checkpoint: FixtureCheckpoint,
    ) -> None:
        retained = replace(
            checkpoint,
            contract=fixture_contract(fixture),
            evidence=evidence_inventory(checkpoint, artefacts),
        )
        self._write(root, artefacts, artefacts / CHECKPOINT_FILE, retained)

    def save_result(
        self,
        root: Path,
        fixture: Fixture,
        artefacts: Path,
        result: TestResult,
    ) -> None:
        checkpoint = result_checkpoint(result)
        self._write(
            root,
            artefacts,
            artefacts / RESULT_FILE,
            StoredTestResult(
                result,
                fixture_contract(fixture),
                evidence_inventory(checkpoint, artefacts),
            ),
        )

    def _read(
        self,
        base: Path,
        path: Path,
        target: type[T],
        *,
        recover_interrupted: bool,
    ) -> T | None:
        try:
            contents = path.read_bytes()
        except FileNotFoundError:
            if not recover_interrupted:
                return None
            return self._recover_pending(base, path, target)
        except OSError as error:
            raise FixtureCheckpointReadError(path, error) from error

        try:
            result = msgspec.json.decode(
                contents,
                type=target,
                dec_hook=lambda kind, value: decode_path(base, kind, value),
            )
        except (ValueError, msgspec.DecodeError, msgspec.ValidationError) as error:
            raise FixtureCheckpointDecodeError(path, error) from error
        validate_checkpoint_paths(result, base, path)
        return result

    def _recover_pending(
        self,
        base: Path,
        path: Path,
        target: type[T],
    ) -> T | None:
        candidates = pending_files(path)
        if not candidates:
            return None
        if len(candidates) != 1:
            raise FixtureCheckpointDecodeError(
                path,
                ValueError("multiple interrupted checkpoint writes exist"),
            )
        (pending,) = candidates
        if pending.is_symlink():
            raise RetainedPathUnsafeError(pending)
        try:
            contents = pending.read_bytes()
        except FileNotFoundError:
            return None
        except OSError as error:
            raise FixtureCheckpointReadError(pending, error) from error

        try:
            result = msgspec.json.decode(
                contents,
                type=target,
                dec_hook=lambda kind, value: decode_path(base, kind, value),
            )
        except (ValueError, msgspec.DecodeError, msgspec.ValidationError):
            try:
                pending.unlink()
            except OSError as error:
                raise FixtureAttemptResetError(pending, error) from error
            return None

        validate_checkpoint_paths(result, base, pending)
        try:
            os.replace(pending, path)
        except OSError as error:
            raise FixtureCheckpointWriteError(path, error) from error
        return result

    def _write(
        self,
        root: Path,
        base: Path,
        path: Path,
        value: StoredValue,
    ) -> None:
        try:
            atomic_write(
                root,
                path,
                msgspec.json.encode(
                    value, enc_hook=lambda item: encode_path(base, item)
                ),
            )
        except OSError as error:
            raise FixtureCheckpointWriteError(path, error) from error

    def _validate_checkpoint(
        self,
        fixture: Fixture,
        checkpoint: FixtureCheckpoint,
        source: Path,
        calibrate: bool,
    ) -> None:
        subject = checkpoint.subject
        expected_checks = tuple(
            (
                check.name,
                check.command,
                check.kind,
                check.expected_return_code,
            )
            for check in fixture.verification
        )
        actual_checks = tuple(
            (
                check.name,
                check.command,
                check.kind,
                check.expected_return_code,
            )
            for check in subject.verification
        )
        expected_calibration = calibration_declaration(fixture) if calibrate else ()
        actual_calibration = calibration_verdicts(checkpoint.calibration)
        if (
            checkpoint.contract != fixture_contract(fixture)
            or subject.name != "candidate"
            or checkpoint.candidate.response != subject.response
            or checkpoint.candidate.trace.resolve() != subject.trace.resolve()
            or subject.workspace.resolve() != subject.evidence.workspace.resolve()
            or subject.evidence.base_revision != fixture.comparison_revision
            or expected_checks != actual_checks
            or (calibrate and expected_calibration != actual_calibration)
        ):
            raise FixtureCheckpointMismatchError(source, fixture.name)

    def _validate_result(
        self,
        fixture: Fixture,
        result: TestResult,
        source: Path,
        calibrate: bool,
        contract: str,
    ) -> None:
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
            contract,
        )
        self._validate_checkpoint(fixture, checkpoint, source, calibrate)
        expected = tuple(sorted(criterion.identifier for criterion in fixture.criteria))
        if tuple(result.judgement.identifiers) != expected:
            raise FixtureCheckpointMismatchError(source, fixture.name)
        result.judgement.validate()


def calibration_state(root: Path, fixture: Fixture) -> Path:
    """Locate the one calibration every arm of a run store shares."""

    return root / CALIBRATION_STATE / f"{fixture.name}.json"


def store_relative(root: Path, artefacts: Path) -> str:
    """Name one fixture attempt by its position inside the run store."""

    try:
        return artefacts.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise RetainedPathUnsafeError(artefacts) from error


def calibration_evidence_root(root: Path, relative: str) -> Path:
    """Recover the fixture attempt whose evidence a shared calibration named."""

    named = Path(relative)
    if named.is_absolute() or any(part in ("", ".", "..") for part in named.parts):
        raise RetainedPathUnsafeError(root / named)
    artefacts = (root / named).resolve()
    if not artefacts.is_relative_to(root.resolve()):
        raise RetainedPathUnsafeError(root / named)
    return artefacts


def encode_path(artefacts: Path, value: object) -> object:
    """Represent run-owned filesystem paths relative to their fixture root."""

    match value:
        case Path():
            try:
                return str(value.resolve().relative_to(artefacts.resolve()))
            except ValueError as error:
                raise FixtureCheckpointMismatchError(
                    artefacts, artefacts.name
                ) from error
        case _:
            raise TypeError(f"unsupported checkpoint value {type(value).__name__}")


def decode_path(artefacts: Path, target: type[object], value: object) -> object:
    """Restore a relative run-owned path requested by a domain dataclass."""

    match target, value:
        case kind, str() if kind is Path:
            relative = Path(value)
            if relative.is_absolute():
                raise ValueError("checkpoint path is absolute")
            result = (artefacts / relative).resolve()
            if not result.is_relative_to(artefacts.resolve()):
                raise ValueError("checkpoint path leaves the fixture result directory")
            return result
        case _:
            raise TypeError(
                f"cannot decode {type(value).__name__} as {target.__name__}"
            )


def validate_checkpoint_paths(
    value: StoredValue,
    artefacts: Path,
    source: Path,
) -> None:
    """Reject decoded evidence paths which grant access outside one fixture."""

    match value:
        case StoredCalibration():
            return
        case StoredTestResult():
            checkpoint = result_checkpoint(value.result)
        case FixtureCheckpoint():
            checkpoint = value

    paths = (
        checkpoint.candidate.transcript,
        checkpoint.candidate.trace,
        checkpoint.subject.workspace,
        checkpoint.subject.trace,
        checkpoint.subject.evidence.workspace,
        checkpoint.subject.evidence.diff,
        checkpoint.subject.evidence.commits,
        *(
            path
            for check in checkpoint.subject.verification
            for path in (check.stdout, check.stderr)
        ),
    )
    root = artefacts.resolve()
    if any(not path.resolve().is_relative_to(root) for path in paths):
        raise FixtureCheckpointMismatchError(source, artefacts.name)


def result_checkpoint(result: TestResult) -> FixtureCheckpoint:
    """Recover the pre-judgement evidence represented by a terminal result."""

    return FixtureCheckpoint(
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


def fixture_contract(fixture: Fixture) -> str:
    """Identify every controlled fixture value and document used by a run."""

    declaration = (
        fixture.name,
        fixture.description,
        fixture.kind.value,
        fixture.use.value,
        fixture.category,
        fixture.tags,
        (fixture.repository.url, fixture.repository.revision),
        fixture.comparison_revision,
        fixture.environment_path,
        tuple(
            (
                criterion.identifier,
                criterion.kind.value,
                criterion.requirement,
                criterion.calibrate,
            )
            for criterion in fixture.criteria
        ),
        tuple(
            (
                check.name,
                check.command,
                check.kind.value,
                check.expected_return_code,
                check.working_directory,
            )
            for check in fixture.verification
        ),
        tuple(
            (
                candidate.name,
                candidate.repository.url,
                candidate.repository.revision,
                candidate.expected_criteria,
            )
            for candidate in fixture.calibration
        ),
        tuple(
            (command.name, command.command, command.working_directory)
            for command in fixture.preparation
        ),
    )
    digest = hashlib.sha256(msgspec.json.encode(declaration))
    contract_document(digest, Path("task"), fixture.task)
    for candidate in fixture.calibration:
        contract_document(
            digest,
            Path("calibration") / candidate.name,
            candidate.response,
        )

    source = Path(fixture.path)
    try:
        files = tuple(
            sorted(
                (
                    path
                    for path in source.rglob("*")
                    if path.is_file() or path.is_symlink()
                ),
                key=lambda path: path.relative_to(source).as_posix(),
            )
        )
    except OSError as error:
        raise FixtureCheckpointEvidenceReadError(source, error) from error
    for path in files:
        if path.is_symlink():
            raise FixtureEvidenceMismatchError(path)
        contract_document(digest, Path("source") / path.relative_to(source), path)
    return digest.hexdigest()


def contract_document(digest: DigestWriter, logical: Path, source: Path) -> None:
    """Add one named fixture document to a contract digest."""

    try:
        contents = source.read_bytes()
    except OSError as error:
        raise FixtureCheckpointEvidenceReadError(source, error) from error
    digest_member(digest, logical.as_posix(), contents)


def digest_member(digest: DigestWriter, name: str, contents: bytes) -> None:
    """Add one unambiguously framed named document to a digest."""

    encoded = name.encode()
    digest.update(len(encoded).to_bytes(8, "big"))
    digest.update(encoded)
    digest.update(len(contents).to_bytes(8, "big"))
    digest.update(contents)


def calibration_declaration(fixture: Fixture) -> CalibrationVerdicts:
    """Describe the reference verdicts a fixture expects its judge to reach."""

    return tuple(
        (candidate.name, candidate.expected_criteria)
        for candidate in fixture.calibration
    )


def calibration_verdicts(
    assessments: tuple[CalibrationAssessment, ...],
) -> CalibrationVerdicts:
    """Describe the reference verdicts one retained calibration recorded."""

    return tuple(
        (
            assessment.candidate,
            tuple(
                sorted(
                    (criterion.identifier, criterion.passed)
                    for criterion in assessment.judgement.criteria
                )
            ),
        )
        for assessment in assessments
    )


def judge_identity(run_metadata: Path) -> str:
    """Identify the judge whose verdicts a retained calibration represents.

    Every member of the run-metadata document is hashed except the candidate
    prompt. The document carries the judge's model, effort and client version,
    so a calibration is only ever reused by the judge which produced it, while
    the arms of one improvement run, which differ in nothing but the prompt the
    candidate is given, share reference judgements each would otherwise pay
    for: those subjects are fixed repository revisions prepared without the
    candidate, and the fixture declares the verdicts they must reach.
    """

    try:
        contents = run_metadata.read_bytes()
    except OSError as error:
        raise FixtureCheckpointEvidenceReadError(run_metadata, error) from error
    try:
        document = msgspec.json.decode(contents, type=dict[str, msgspec.Raw])
    except (msgspec.DecodeError, msgspec.ValidationError) as error:
        raise RunMetadataDecodeError(run_metadata, error) from error

    digest = hashlib.sha256()
    for name, member in sorted(document.items()):
        if name in CANDIDATE_PROMPT_MEMBERS:
            continue
        digest_member(digest, name, bytes(member))
    return digest.hexdigest()


def calibration_inventory(artefacts: Path) -> tuple[EvidenceDigest, ...]:
    """Hash the exact retained files which support the reference judgements."""

    root = artefacts / CALIBRATION_DIRECTORY
    try:
        if not root.is_dir() or root.is_symlink():
            raise FixtureEvidenceMismatchError(root)
        entries = tuple(root.rglob("*"))
    except OSError as error:
        raise FixtureEvidenceReadError(root, error) from error

    return tuple(
        evidence_digest(path, artefacts)
        for path in sorted(entries, key=lambda item: str(item))
    )


def evidence_inventory(
    checkpoint: FixtureCheckpoint,
    artefacts: Path,
) -> tuple[EvidenceDigest, ...]:
    """Hash the exact retained files which support a candidate judgement."""

    direct = {
        checkpoint.candidate.transcript.resolve(),
        checkpoint.candidate.trace.resolve(),
        checkpoint.subject.trace.resolve(),
        checkpoint.subject.evidence.diff.resolve(),
        checkpoint.subject.evidence.commits.resolve(),
        *(
            path.resolve()
            for check in checkpoint.subject.verification
            for path in (check.stdout, check.stderr)
        ),
    }
    workspace = checkpoint.subject.workspace.resolve()
    try:
        if not workspace.is_dir() or workspace.is_symlink():
            raise FixtureEvidenceMismatchError(workspace)
        workspace_entries = tuple(workspace.rglob("*"))
    except OSError as error:
        raise FixtureEvidenceReadError(workspace, error) from error

    return tuple(
        evidence_digest(path, artefacts)
        for path in sorted((*direct, *workspace_entries), key=lambda item: str(item))
    )


def evidence_digest(path: Path, artefacts: Path) -> EvidenceDigest:
    """Identify one retained directory, regular file, or symbolic link."""

    try:
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            kind = "symlink"
            contents = os.readlink(path).encode(errors="surrogateescape")
            executable = False
        elif stat.S_ISREG(metadata.st_mode):
            kind = "file"
            contents = path.read_bytes()
            executable = bool(metadata.st_mode & stat.S_IXUSR)
        elif stat.S_ISDIR(metadata.st_mode):
            kind = "directory"
            contents = b""
            executable = False
        else:
            raise FixtureEvidenceMismatchError(path)
        relative = path.relative_to(artefacts.resolve())
    except FixtureEvidenceMismatchError:
        raise
    except OSError as error:
        raise FixtureEvidenceReadError(path, error) from error
    except ValueError as error:
        raise FixtureEvidenceMismatchError(path) from error
    return EvidenceDigest(
        relative.as_posix(),
        kind,
        hashlib.sha256(contents).hexdigest(),
        executable,
    )


def validate_evidence(
    checkpoint: FixtureCheckpoint,
    expected: tuple[EvidenceDigest, ...],
    artefacts: Path,
    source: Path,
) -> None:
    """Require resumed evidence to match the exact inventory originally retained."""

    actual = evidence_inventory(checkpoint, artefacts)
    if actual != expected:
        raise FixtureEvidenceMismatchError(source)
