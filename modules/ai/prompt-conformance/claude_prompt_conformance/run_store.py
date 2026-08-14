"""Lifecycle of a resumable, self-describing conformance run directory."""

import hashlib
import os
import shutil
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path

import msgspec

from .errors import ConformanceError
from .inputs import MaterialisedRuntime, RuntimeInputs
from .models import RuntimeConfiguration
from .storage import (
    OUTPUT_MARKER,
    STATE_DIRECTORY,
    RetainedPathUnsafeError,
    atomic_write,
    directory_identity,
    pending_files,
    read_regular_file,
    remove_identified_directory,
    remove_tree,
    synchronise_directory,
)


@dataclass(eq=True)
class ProtectedOutputPathError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"refusing to use protected output path {self.path}"


@dataclass(eq=True)
class OutputPathNotDirectoryError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"output path is not a directory: {self.path}"


@dataclass(eq=True)
class OutputPathUnmarkedError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"refusing to replace unmarked output directory: {self.path}"


@dataclass(eq=True)
class OutputSnapshotMismatchError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return (
            f"output directory {self.path} belongs to different run inputs; "
            "use --unlink-first to remove it and start again"
        )


@dataclass(eq=True)
class RunStoreCreateError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not create run store {self.path}: {self.cause}"


@dataclass(eq=True)
class RunStorePublishError(ConformanceError):
    source: Path
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not publish run store {self.destination}: {self.cause}"


@dataclass(eq=True)
class RunStoreInitialisationResetError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not reset incomplete run-store initialisation {self.path}: {self.cause}"


@dataclass(eq=True)
class OutputMarkerReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read output marker {self.source}: {self.cause}"


@dataclass(eq=True)
class OutputMarkerDecodeError(ConformanceError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"output marker {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class OutputMarkerWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not retain output marker {self.destination}: {self.cause}"


@dataclass(eq=True)
class OutputUnlinkError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not unlink prior run store {self.path}: {self.cause}"


RUN_STORE_VERSION = 4
INPUT_DIRECTORY = f"{STATE_DIRECTORY}/inputs"
PROMPT_CONTEXT_DOCUMENT = "prompt-context.json"
RUN_METADATA_DOCUMENT = "run-metadata.json"


class RunInvocation(msgspec.Struct, frozen=True, rename="camel"):
    """Command semantics which must remain stable while a run is resumed."""

    fixtures: tuple[str, ...]
    improve: bool
    calibrate: bool
    proposals: int
    samples: int
    keep_workspaces: bool

    def __post_init__(self) -> None:
        """Treat the fixture selection as the set it denotes."""

        msgspec.structs.force_setattr(
            self,
            "fixtures",
            tuple(sorted(set(self.fixtures))),
        )


class RunMarker(msgspec.Struct, frozen=True, rename="camel"):
    """Identity and retained-document locations for one run store."""

    prompt_context: str
    run_metadata: str
    fingerprint: str
    invocation: RunInvocation
    ready: bool = True


@dataclass(frozen=True)
class RunStore:
    """Open a new or existing output path using the same automatic semantics."""

    path: Path

    @classmethod
    def open(
        cls,
        output: Path,
        inputs: RuntimeInputs,
        invocation: RunInvocation,
        *,
        unlink_first: bool,
    ) -> tuple["RunStore", MaterialisedRuntime]:
        resolved = output.resolve()
        protect_output_path(resolved)
        store = cls(resolved)
        marker = store._existing_marker(unlink_first)
        fingerprint = run_fingerprint(inputs, invocation)
        if marker is None:
            return cls._create(resolved, inputs, invocation, fingerprint)

        if (
            marker.fingerprint != fingerprint
            or marker.prompt_context != PROMPT_CONTEXT_DOCUMENT
            or marker.run_metadata != RUN_METADATA_DOCUMENT
        ):
            raise OutputSnapshotMismatchError(resolved)

        if marker.ready:
            return store._resume(inputs, invocation, fingerprint)
        return store._reinitialise(inputs, invocation, fingerprint)

    def _resume(
        self,
        current: RuntimeInputs,
        invocation: RunInvocation,
        fingerprint: str,
    ) -> tuple["RunStore", MaterialisedRuntime]:
        """Reuse a complete retained snapshot which authenticates the run identity."""

        root = self.path / INPUT_DIRECTORY
        retained = RuntimeInputs.load(root / "configuration.json")
        runtime = retained.reuse_materialised(root)
        if run_fingerprint(retained, invocation) != fingerprint:
            raise OutputSnapshotMismatchError(self.path)

        execution = RuntimeConfiguration.from_input(
            runtime.configuration.source,
            current.declaration,
        )
        return self, refresh_execution(runtime, execution)

    def _reinitialise(
        self,
        inputs: RuntimeInputs,
        invocation: RunInvocation,
        fingerprint: str,
    ) -> tuple["RunStore", MaterialisedRuntime]:
        """Rebuild the snapshot of a store interrupted while it was initialising."""

        self._reset_incomplete_initialisation()
        self._write_marker(fingerprint, invocation, ready=False)
        runtime = inputs.materialise(self.path / INPUT_DIRECTORY)
        inputs.run_metadata.materialise(self.path / RUN_METADATA_DOCUMENT)
        inputs.prompt_context.materialise(self.path / PROMPT_CONTEXT_DOCUMENT)
        self._write_marker(fingerprint, invocation, ready=True)
        return self, runtime

    @classmethod
    def _create(
        cls,
        output: Path,
        inputs: RuntimeInputs,
        invocation: RunInvocation,
        fingerprint: str,
    ) -> tuple["RunStore", MaterialisedRuntime]:
        """Construct a complete initial store before publishing it atomically."""

        try:
            output.parent.mkdir(parents=True, exist_ok=True)
            staging = Path(
                tempfile.mkdtemp(
                    prefix=f".{output.name}.initialising-",
                    dir=output.parent,
                )
            )
        except OSError as error:
            raise RunStoreCreateError(output, error) from error

        staged = cls(staging)
        published = False
        try:
            staged._write_marker(fingerprint, invocation, ready=False)
            runtime = inputs.materialise(
                staging / INPUT_DIRECTORY,
                logical_root=output / INPUT_DIRECTORY,
            )
            inputs.run_metadata.materialise(staging / RUN_METADATA_DOCUMENT)
            inputs.prompt_context.materialise(staging / PROMPT_CONTEXT_DOCUMENT)
            staged._write_marker(fingerprint, invocation, ready=True)
            try:
                os.replace(staging, output)
                synchronise_directory(output.parent)
            except OSError as error:
                raise RunStorePublishError(staging, output, error) from error
            published = True
        finally:
            if not published:
                shutil.rmtree(staging, ignore_errors=True)

        store = cls(output)
        return store, runtime

    def _existing_marker(self, unlink_first: bool) -> RunMarker | None:
        if not self.path.exists():
            return None
        try:
            identity = directory_identity(self.path.parent, self.path)
        except RetainedPathUnsafeError as error:
            raise OutputPathNotDirectoryError(self.path) from error

        marker_path = self.path / OUTPUT_MARKER
        try:
            contents = read_regular_file(self.path, marker_path)
        except FileNotFoundError:
            marker = self._recover_pending_marker(marker_path)
        except RetainedPathUnsafeError as error:
            raise OutputPathUnmarkedError(self.path) from error
        except OSError as error:
            raise OutputMarkerReadError(marker_path, error) from error
        else:
            marker = self._decode_marker(marker_path, contents)

        if not unlink_first:
            return marker

        try:
            remove_identified_directory(self.path.parent, self.path, identity)
        except OSError as error:
            raise OutputUnlinkError(self.path, error) from error
        return None

    def _recover_pending_marker(self, marker_path: Path) -> RunMarker | None:
        candidates = pending_files(marker_path)
        if len(candidates) != 1:
            raise OutputPathUnmarkedError(self.path)
        (pending,) = candidates
        try:
            contents = read_regular_file(self.path, pending)
        except FileNotFoundError as error:
            raise OutputPathUnmarkedError(self.path) from error
        except RetainedPathUnsafeError as error:
            raise OutputPathUnmarkedError(self.path) from error
        except OSError as error:
            raise OutputMarkerReadError(pending, error) from error

        marker = self._decode_marker(pending, contents)
        try:
            os.replace(pending, marker_path)
        except OSError as error:
            raise OutputMarkerWriteError(marker_path, error) from error
        return marker

    def _decode_marker(self, source: Path, contents: bytes) -> RunMarker:
        """Read one marker, treating another store format as a foreign store."""

        try:
            return msgspec.json.decode(contents, type=RunMarker)
        except msgspec.ValidationError as error:
            raise OutputSnapshotMismatchError(self.path) from error
        except msgspec.DecodeError as error:
            raise OutputMarkerDecodeError(source, error) from error

    def _reset_incomplete_initialisation(self) -> None:
        state = self.path / STATE_DIRECTORY
        try:
            if state.is_symlink() or state.is_file():
                state.unlink()
            elif state.is_dir():
                remove_tree(state)
            for name in (RUN_METADATA_DOCUMENT, PROMPT_CONTEXT_DOCUMENT):
                document = self.path / name
                if document.is_symlink() or document.is_file():
                    document.unlink()
        except OSError as error:
            raise RunStoreInitialisationResetError(self.path, error) from error

    def _write_marker(
        self,
        fingerprint: str,
        invocation: RunInvocation,
        *,
        ready: bool,
    ) -> None:
        marker = RunMarker(
            prompt_context=PROMPT_CONTEXT_DOCUMENT,
            run_metadata=RUN_METADATA_DOCUMENT,
            fingerprint=fingerprint,
            invocation=invocation,
            ready=ready,
        )
        destination = self.path / OUTPUT_MARKER
        try:
            atomic_write(
                self.path,
                destination,
                msgspec.json.encode(marker) + b"\n",
            )
        except OSError as error:
            raise OutputMarkerWriteError(destination, error) from error


def protect_output_path(output: Path) -> None:
    """Reject broad paths which must never become managed run stores."""

    protected = {
        Path(output.anchor),
        Path.cwd().resolve(),
        Path.home().resolve(),
    }
    if output in protected:
        raise ProtectedOutputPathError(output)


def run_fingerprint(inputs: RuntimeInputs, invocation: RunInvocation) -> str:
    """Combine controlled data and command semantics into one run identity."""

    digest = hashlib.sha256()
    digest.update(RUN_STORE_VERSION.to_bytes(8, "big"))
    digest.update(inputs.fingerprint().encode())
    digest.update(msgspec.json.encode(invocation))
    return digest.hexdigest()


def refresh_execution(
    runtime: MaterialisedRuntime,
    execution: RuntimeConfiguration,
) -> MaterialisedRuntime:
    """Use current executables while retaining the run's immutable data paths."""

    retained = runtime.configuration
    configuration = replace(
        retained,
        git_program=execution.git_program,
        claude=replace(execution.claude, settings=retained.claude.settings),
        codex=replace(
            execution.codex,
            schema=retained.codex.schema,
            proposal_schema=retained.codex.proposal_schema,
            tls_certificate_bundle=retained.codex.tls_certificate_bundle,
        ),
        isolation=execution.isolation,
        variant=replace(
            execution.variant,
            expression=retained.variant.expression,
            prompt_environment=retained.variant.prompt_environment,
            prompt_source=retained.variant.prompt_source,
        ),
    )
    return replace(runtime, configuration=configuration)
