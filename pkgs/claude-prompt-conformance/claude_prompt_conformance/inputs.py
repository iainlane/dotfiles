"""Eager loading and run-owned materialisation of immutable Nix inputs."""

import hashlib
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import msgspec

from .errors import ConformanceError
from .models import Fixture, RuntimeConfiguration
from .protocols.configuration import FixtureInput, RuntimeConfigurationInput
from .storage import RESERVED_RUN_NAMES


@dataclass(eq=True)
class RuntimeConfigurationReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read runtime configuration {self.source}: {self.cause}"


@dataclass(eq=True)
class RuntimeConfigurationDecodeError(ConformanceError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"runtime configuration {self.source} is invalid: {self.cause}"


@dataclass(eq=True)
class RuntimeInputDocumentReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read immutable run document {self.source}: {self.cause}"


@dataclass(eq=True)
class RuntimeInputDocumentTypeError(ConformanceError):
    source: Path

    def __str__(self) -> str:
        return f"immutable run document is not a regular file: {self.source}"


@dataclass(eq=True)
class RuntimeInputDirectoryReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not traverse immutable run directory {self.source}: {self.cause}"


@dataclass(eq=True)
class RuntimeInputDirectoryTypeError(ConformanceError):
    source: Path

    def __str__(self) -> str:
        return f"immutable run directory is not a directory: {self.source}"


@dataclass(eq=True)
class RuntimeInputDocumentWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return (
            f"could not retain immutable run document {self.destination}: {self.cause}"
        )


@dataclass(eq=True)
class RuntimeInputCollisionError(ConformanceError):
    destination: Path

    def __str__(self) -> str:
        return (
            f"immutable run input destination is not a regular file: {self.destination}"
        )


@dataclass(eq=True)
class RuntimeInputSnapshotInventoryError(ConformanceError):
    path: Path
    expected: tuple[Path, ...]
    actual: tuple[Path, ...]

    def __str__(self) -> str:
        missing = tuple(path for path in self.expected if path not in self.actual)
        unexpected = tuple(path for path in self.actual if path not in self.expected)
        return (
            f"retained immutable run input inventory does not match this run: "
            f"{self.path}; missing {missing!r}; unexpected {unexpected!r}"
        )


@dataclass(eq=True)
class RuntimeInputSnapshotDocumentMismatchError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"retained immutable run document does not match this run: {self.path}"


@dataclass(eq=True)
class FixtureManifestDecodeError(ConformanceError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"fixture manifest {self.source} is invalid JSON: {self.cause}"


@dataclass(eq=True)
class FixtureManifestDomainError(ConformanceError):
    source: Path
    cause: ValueError

    def __str__(self) -> str:
        return f"fixture manifest {self.source} has invalid domain values: {self.cause}"


@dataclass(eq=True)
class FixtureNameError(ConformanceError):
    name: str

    def __str__(self) -> str:
        return f"fixture name is not a safe path component: {self.name!r}"


@dataclass(eq=True)
class CalibrationNameError(ConformanceError):
    fixture: str
    name: str

    def __str__(self) -> str:
        return (
            f"calibration name in fixture {self.fixture!r} is not a safe path "
            f"component: {self.name!r}"
        )


@dataclass(eq=True)
class DuplicateFixtureDefinitionError(ConformanceError):
    names: tuple[str, ...]

    def __str__(self) -> str:
        return f"fixture manifest contains duplicate names: {self.names!r}"


@dataclass(eq=True)
class DuplicateCalibrationDefinitionError(ConformanceError):
    fixture: str
    names: tuple[str, ...]

    def __str__(self) -> str:
        return f"fixture {self.fixture!r} contains duplicate calibration names: {self.names!r}"


@dataclass(frozen=True)
class MemoryFile:
    """A regular file whose complete contents are retained in process memory."""

    contents: bytes
    executable: bool

    @classmethod
    def load(cls, source: Path) -> "MemoryFile":
        try:
            metadata = source.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeInputDocumentTypeError(source)
            return cls(
                contents=source.read_bytes(),
                executable=bool(metadata.st_mode & stat.S_IXUSR),
            )
        except RuntimeInputDocumentTypeError:
            raise
        except OSError as error:
            raise RuntimeInputDocumentReadError(source, error) from error

    def materialise(self, destination: Path) -> None:
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink() or (
                destination.exists() and not destination.is_file()
            ):
                raise RuntimeInputCollisionError(destination)
            destination.write_bytes(self.contents)
            destination.chmod(0o755 if self.executable else 0o644)
        except RuntimeInputCollisionError:
            raise
        except OSError as error:
            raise RuntimeInputDocumentWriteError(destination, error) from error

    def update_hash(self, digest: "HashWriter", name: str) -> None:
        """Add the file's contents and executable mode to an input identity."""

        update_hash(digest, f"{name}:executable", bytes((self.executable,)))
        update_hash(digest, f"{name}:contents", self.contents)


@dataclass(frozen=True)
class MemoryTreeEntry:
    """One logical regular file captured from an immutable directory tree."""

    relative: Path
    file: MemoryFile


@dataclass(frozen=True)
class MemoryTree:
    """A directory tree captured without retaining lazy source-path reads."""

    files: tuple[MemoryTreeEntry, ...]

    @classmethod
    def load(cls, source: Path) -> "MemoryTree":
        try:
            if not source.is_dir():
                raise RuntimeInputDirectoryTypeError(source)
            files = tuple(
                MemoryTreeEntry(
                    path.relative_to(source),
                    MemoryFile.load(path),
                )
                for directory, _directories, names in os.walk(
                    source,
                    followlinks=True,
                    onerror=raise_directory_error,
                )
                for path in (Path(directory) / name for name in sorted(names))
            )
        except RuntimeInputDirectoryTypeError:
            raise
        except OSError as error:
            raise RuntimeInputDirectoryReadError(source, error) from error

        return cls(tuple(sorted(files, key=lambda entry: entry.relative.as_posix())))

    def materialise(self, destination: Path) -> None:
        for entry in self.files:
            entry.file.materialise(destination / entry.relative)

    def update_hash(self, digest: "HashWriter") -> None:
        for entry in self.files:
            entry.file.update_hash(digest, entry.relative.as_posix())


@dataclass(frozen=True)
class FixtureInputs:
    """A decoded fixture declaration and all files below its Nix source root."""

    declaration: FixtureInput
    tree: MemoryTree
    task: MemoryFile
    calibration: tuple[MemoryFile, ...]


@dataclass(frozen=True)
class MaterialisedRuntime:
    """Run-owned configuration and fixtures detached from immutable data paths."""

    configuration: RuntimeConfiguration
    fixtures: tuple[Fixture, ...]


@dataclass(frozen=True)
class RuntimeInputs:
    """Every small immutable document needed after a conformance run starts."""

    declaration: RuntimeConfigurationInput
    fixture_manifest: MemoryFile
    run_metadata: MemoryFile
    prompt_context: MemoryFile
    claude_settings: MemoryFile
    judge_schema: MemoryFile
    proposal_schema: MemoryFile
    tls_certificate_bundle: MemoryFile
    variant_source: MemoryTree
    candidate_context: MemoryTree
    workspace_overlay: MemoryTree
    prompt_source: MemoryTree
    fixtures: tuple[FixtureInputs, ...]

    @classmethod
    def load(cls, source: Path) -> "RuntimeInputs":
        """Read and decode all immutable run documents before model work begins."""

        try:
            contents = source.read_bytes()
        except OSError as error:
            raise RuntimeConfigurationReadError(source, error) from error

        try:
            declaration = msgspec.json.decode(
                contents,
                type=RuntimeConfigurationInput,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise RuntimeConfigurationDecodeError(source, error) from error

        return cls._load_declaration(declaration)

    @classmethod
    def _load_declaration(
        cls,
        declaration: RuntimeConfigurationInput,
    ) -> "RuntimeInputs":
        """Load every immutable document referenced by a decoded declaration."""

        fixture_manifest_path = Path(declaration.fixture_manifest)
        fixture_manifest = MemoryFile.load(fixture_manifest_path)
        try:
            fixture_declarations = msgspec.json.decode(
                fixture_manifest.contents,
                type=tuple[FixtureInput, ...],
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise FixtureManifestDecodeError(fixture_manifest_path, error) from error

        result = cls(
            declaration=declaration,
            fixture_manifest=fixture_manifest,
            run_metadata=MemoryFile.load(Path(declaration.run_metadata)),
            prompt_context=MemoryFile.load(Path(declaration.prompt_context)),
            claude_settings=MemoryFile.load(Path(declaration.claude.settings)),
            judge_schema=MemoryFile.load(Path(declaration.codex.schema)),
            proposal_schema=MemoryFile.load(Path(declaration.codex.proposal_schema)),
            tls_certificate_bundle=MemoryFile.load(
                Path(declaration.codex.tls_certificate_bundle)
            ),
            variant_source=MemoryTree.load(Path(declaration.variant.expression).parent),
            candidate_context=MemoryTree.load(Path(declaration.candidate_context)),
            workspace_overlay=MemoryTree.load(Path(declaration.workspace_overlay)),
            prompt_source=MemoryTree.load(Path(declaration.variant.prompt_source)),
            fixtures=tuple(
                FixtureInputs(
                    declaration=fixture,
                    tree=MemoryTree.load(Path(fixture.path)),
                    task=MemoryFile.load(Path(fixture.task)),
                    calibration=tuple(
                        MemoryFile.load(Path(candidate.response))
                        for candidate in fixture.calibration
                    ),
                )
                for fixture in fixture_declarations
            ),
        )
        try:
            validate_fixture_names(fixture_declarations)
            result.source_fixtures()
            tuple(
                rebase_fixture(fixture.declaration, Path("fixtures"))
                for fixture in result.fixtures
            )
        except ValueError as error:
            raise FixtureManifestDomainError(fixture_manifest_path, error) from error
        return result

    def source_fixtures(self) -> tuple[Fixture, ...]:
        """Expose decoded fixtures for selection without rereading their manifest."""

        return tuple(Fixture.from_input(item.declaration) for item in self.fixtures)

    def fingerprint(self) -> str:
        """Identify the controlled experiment inputs independently of harness code."""

        declaration = self.declaration
        digest = hashlib.sha256()
        normalized_declaration = msgspec.structs.replace(
            declaration,
            fixture_manifest="fixture-manifest",
            run_metadata="run-metadata",
            prompt_context="prompt-context",
            candidate_context="candidate-context",
            workspace_overlay="workspace-overlay",
            git_program="git",
            claude=msgspec.structs.replace(
                declaration.claude,
                program="claude",
                shell="shell",
                settings="claude-settings",
            ),
            codex=msgspec.structs.replace(
                declaration.codex,
                program="codex",
                mcp_program="conformance-mcp",
                schema="judge-schema",
                proposal_schema="proposal-schema",
                tls_certificate_bundle="tls-certificate-bundle",
            ),
            isolation=msgspec.structs.replace(
                declaration.isolation,
                program=(
                    "isolation" if declaration.isolation.program is not None else None
                ),
            ),
            variant=msgspec.structs.replace(
                declaration.variant,
                nix_program="nix",
                expression="variant-expression",
                prompt_environment="variant-prompt-environment",
                prompt_source="prompt-source",
            ),
        )
        update_hash(
            digest,
            "runtime-configuration",
            msgspec.json.encode(normalized_declaration),
        )
        for name, document in (
            ("run-metadata", self.run_metadata),
            ("prompt-context", self.prompt_context),
            ("claude-settings", self.claude_settings),
            ("judge-schema", self.judge_schema),
            ("proposal-schema", self.proposal_schema),
            ("tls-certificate-bundle", self.tls_certificate_bundle),
        ):
            document.update_hash(digest, name)

        for name, tree in (
            ("candidate-context", self.candidate_context),
            ("workspace-overlay", self.workspace_overlay),
            ("prompt-source", controlled_prompt_source(self.prompt_source)),
            ("variant-source", self.variant_source),
        ):
            update_hash(digest, f"{name}:begin", b"")
            tree.update_hash(digest)
            update_hash(digest, f"{name}:end", b"")

        for fixture in self.fixtures:
            logical = rebase_fixture(fixture.declaration, Path("fixtures"))
            update_hash(
                digest,
                f"fixture:{fixture.declaration.name}:declaration",
                msgspec.json.encode(logical),
            )
            update_hash(
                digest,
                f"fixture:{fixture.declaration.name}:begin",
                b"",
            )
            fixture.tree.update_hash(digest)
            fixture.task.update_hash(
                digest,
                f"fixture:{fixture.declaration.name}:task",
            )
            for candidate, response in zip(
                fixture.declaration.calibration,
                fixture.calibration,
                strict=True,
            ):
                response.update_hash(
                    digest,
                    f"fixture:{fixture.declaration.name}:calibration:{candidate.name}",
                )
            update_hash(
                digest,
                f"fixture:{fixture.declaration.name}:end",
                b"",
            )
        return digest.hexdigest()

    def materialise(
        self,
        root: Path,
        *,
        logical_root: Path | None = None,
    ) -> MaterialisedRuntime:
        """Write the memory snapshot beneath a run-owned root and rebase its paths."""

        destinations = RuntimeInputPaths(root)
        paths = RuntimeInputPaths(logical_root or root)
        self.run_metadata.materialise(destinations.run_metadata)
        self.prompt_context.materialise(destinations.prompt_context)
        self.claude_settings.materialise(destinations.claude_settings)
        self.judge_schema.materialise(destinations.judge_schema)
        self.proposal_schema.materialise(destinations.proposal_schema)
        self.tls_certificate_bundle.materialise(destinations.tls_certificate_bundle)
        self.variant_source.materialise(destinations.variant_source)
        self.candidate_context.materialise(destinations.candidate_context)
        self.workspace_overlay.materialise(destinations.workspace_overlay)
        self.prompt_source.materialise(destinations.prompt_source)

        declarations = self.fixture_declarations_at(paths)
        destinations_by_fixture = self.fixture_declarations_at(destinations)
        for fixture, destination in zip(
            self.fixtures,
            destinations_by_fixture,
            strict=True,
        ):
            fixture.tree.materialise(Path(destination.path))
            fixture.task.materialise(Path(destination.task))
            for candidate, response in zip(
                destination.calibration,
                fixture.calibration,
                strict=True,
            ):
                response.materialise(Path(candidate.response))
        MemoryFile(msgspec.json.encode(declarations), False).materialise(
            destinations.fixture_manifest
        )

        declaration = self.declaration_at(paths)
        MemoryFile(msgspec.json.encode(declaration), False).materialise(
            destinations.configuration
        )
        return self.runtime_at(paths, declaration, declarations)

    def reuse_materialised(
        self,
        root: Path,
        configuration_document: MemoryFile | None = None,
    ) -> MaterialisedRuntime:
        """Validate and reuse a complete run-owned snapshot without rewriting it."""

        paths = RuntimeInputPaths(root)
        declarations = self.fixture_declarations_at(paths)
        declaration = self.declaration_at(paths)
        expected = dict(self.materialised_files(paths, declaration, declarations))
        if configuration_document is not None:
            expected[paths.configuration.relative_to(root)] = configuration_document
        actual = materialised_files(root)
        expected_paths = tuple(sorted(expected, key=Path.as_posix))
        if expected_paths != actual:
            raise RuntimeInputSnapshotInventoryError(
                root,
                expected_paths,
                actual,
            )

        for relative, document in expected.items():
            retained = MemoryFile.load(root / relative)
            if retained != document:
                raise RuntimeInputSnapshotDocumentMismatchError(root / relative)

        return self.runtime_at(paths, declaration, declarations)

    def fixture_declarations_at(
        self,
        paths: "RuntimeInputPaths",
    ) -> tuple[FixtureInput, ...]:
        """Rebase fixture declarations beneath one retained input root."""

        return tuple(
            rebase_fixture(fixture.declaration, paths.fixtures)
            for fixture in self.fixtures
        )

    def declaration_at(
        self,
        paths: "RuntimeInputPaths",
    ) -> RuntimeConfigurationInput:
        """Rebase the runtime declaration beneath one retained input root."""

        return msgspec.structs.replace(
            self.declaration,
            fixture_manifest=str(paths.fixture_manifest),
            run_metadata=str(paths.run_metadata),
            prompt_context=str(paths.prompt_context),
            candidate_context=str(paths.candidate_context),
            workspace_overlay=str(paths.workspace_overlay),
            claude=msgspec.structs.replace(
                self.declaration.claude,
                settings=str(paths.claude_settings),
            ),
            codex=msgspec.structs.replace(
                self.declaration.codex,
                schema=str(paths.judge_schema),
                proposal_schema=str(paths.proposal_schema),
                tls_certificate_bundle=str(paths.tls_certificate_bundle),
            ),
            variant=msgspec.structs.replace(
                self.declaration.variant,
                expression=str(paths.variant_expression),
                prompt_environment=str(paths.variant_prompt_environment),
                prompt_source=str(paths.prompt_source),
            ),
        )

    def materialised_files(
        self,
        paths: "RuntimeInputPaths",
        declaration: RuntimeConfigurationInput,
        fixtures: tuple[FixtureInput, ...],
    ) -> tuple[tuple[Path, MemoryFile], ...]:
        """Describe the exact regular-file inventory of a retained snapshot."""

        documents = (
            (paths.configuration, MemoryFile(msgspec.json.encode(declaration), False)),
            (paths.fixture_manifest, MemoryFile(msgspec.json.encode(fixtures), False)),
            (paths.run_metadata, self.run_metadata),
            (paths.prompt_context, self.prompt_context),
            (paths.claude_settings, self.claude_settings),
            (paths.judge_schema, self.judge_schema),
            (paths.proposal_schema, self.proposal_schema),
            (paths.tls_certificate_bundle, self.tls_certificate_bundle),
        )
        trees = (
            (paths.candidate_context, self.candidate_context),
            (paths.workspace_overlay, self.workspace_overlay),
            (paths.prompt_source, self.prompt_source),
            (paths.variant_source, self.variant_source),
            *(
                (Path(declaration.path), fixture.tree)
                for declaration, fixture in zip(fixtures, self.fixtures, strict=True)
            ),
        )
        fixture_documents = tuple(
            (Path(declaration.task), fixture.task)
            for declaration, fixture in zip(fixtures, self.fixtures, strict=True)
        ) + tuple(
            (Path(candidate.response), response)
            for declaration, fixture in zip(fixtures, self.fixtures, strict=True)
            for candidate, response in zip(
                declaration.calibration,
                fixture.calibration,
                strict=True,
            )
        )
        return (
            tuple(
                (path.relative_to(paths.root), document) for path, document in documents
            )
            + tuple(
                (path.relative_to(paths.root), document)
                for path, document in fixture_documents
            )
            + tuple(
                (
                    (root / entry.relative).relative_to(paths.root),
                    entry.file,
                )
                for root, tree in trees
                for entry in tree.files
            )
        )

    def runtime_at(
        self,
        paths: "RuntimeInputPaths",
        declaration: RuntimeConfigurationInput,
        fixtures: tuple[FixtureInput, ...],
    ) -> MaterialisedRuntime:
        """Construct domain values referring to an already retained snapshot."""

        return MaterialisedRuntime(
            configuration=RuntimeConfiguration.from_input(
                paths.configuration,
                declaration,
            ),
            fixtures=tuple(Fixture.from_input(item) for item in fixtures),
        )


@dataclass(frozen=True)
class RuntimeInputPaths:
    """Stable locations of all run-owned immutable input snapshots."""

    root: Path

    @property
    def configuration(self) -> Path:
        return self.root / "configuration.json"

    @property
    def fixture_manifest(self) -> Path:
        return self.root / "fixtures.json"

    @property
    def run_metadata(self) -> Path:
        return self.root / "run-metadata.json"

    @property
    def prompt_context(self) -> Path:
        return self.root / "prompt-context.json"

    @property
    def claude_settings(self) -> Path:
        return self.root / "claude-settings.json"

    @property
    def judge_schema(self) -> Path:
        return self.root / "judgement-schema.json"

    @property
    def proposal_schema(self) -> Path:
        return self.root / "proposal-schema.json"

    @property
    def tls_certificate_bundle(self) -> Path:
        return self.root / "ca-bundle.crt"

    @property
    def variant_expression(self) -> Path:
        return self.variant_source / "variant.nix"

    @property
    def variant_prompt_environment(self) -> Path:
        return self.variant_source / "prompt-environment.nix"

    @property
    def variant_source(self) -> Path:
        return self.root / "variant-source"

    @property
    def candidate_context(self) -> Path:
        return self.root / "candidate-context"

    @property
    def workspace_overlay(self) -> Path:
        return self.root / "workspace-overlay"

    @property
    def prompt_source(self) -> Path:
        return self.root / "prompt-source"

    @property
    def fixtures(self) -> Path:
        return self.root / "fixtures"


def rebase_fixture(value: FixtureInput, fixtures: Path) -> FixtureInput:
    """Point a fixture declaration at the corresponding run-owned tree."""

    destination = fixtures / value.name
    return msgspec.structs.replace(
        value,
        path=str(destination / "source"),
        task=str(destination / "task.md"),
        calibration=tuple(
            msgspec.structs.replace(
                candidate,
                response=str(destination / "calibration" / f"{candidate.name}.md"),
            )
            for candidate in value.calibration
        ),
    )


def validate_fixture_names(fixtures: tuple[FixtureInput, ...]) -> None:
    """Require every manifest-controlled path component to be safe and unique."""

    names = tuple(fixture.name for fixture in fixtures)
    duplicates = duplicate_names(names)
    if duplicates:
        raise DuplicateFixtureDefinitionError(duplicates)

    for fixture in fixtures:
        if not safe_path_component(fixture.name) or fixture.name in RESERVED_RUN_NAMES:
            raise FixtureNameError(fixture.name)
        calibration = tuple(candidate.name for candidate in fixture.calibration)
        duplicates = duplicate_names(calibration)
        if duplicates:
            raise DuplicateCalibrationDefinitionError(fixture.name, duplicates)
        for name in calibration:
            if not safe_path_component(name):
                raise CalibrationNameError(fixture.name, name)


def safe_path_component(value: str) -> bool:
    """Return whether a manifest name denotes exactly one ordinary component."""

    return bool(value) and value not in (".", "..") and Path(value).name == value


def duplicate_names(values: tuple[str, ...]) -> tuple[str, ...]:
    """Return repeated names once, in deterministic lexical order."""

    return tuple(sorted({value for value in values if values.count(value) > 1}))


class HashWriter(Protocol):
    """The subset of a hash implementation used by input snapshots."""

    def update(self, contents: bytes, /) -> None: ...


def raise_directory_error(error: OSError) -> None:
    """Keep directory traversal failures inside the typed input boundary."""

    raise error


def materialised_files(root: Path) -> tuple[Path, ...]:
    """List regular files without following links out of a retained snapshot."""

    files: list[Path] = []
    try:
        for directory, directories, names in os.walk(
            root,
            followlinks=False,
            onerror=raise_directory_error,
        ):
            parent = Path(directory)
            for name in (*directories, *names):
                path = parent / name
                if path.is_symlink():
                    raise RuntimeInputSnapshotDocumentMismatchError(path)
            files.extend(
                (parent / name).relative_to(root)
                for name in names
                if (parent / name).is_file()
            )
    except RuntimeInputSnapshotDocumentMismatchError:
        raise
    except OSError as error:
        raise RuntimeInputDirectoryReadError(root, error) from error
    return tuple(sorted(files, key=Path.as_posix))


def update_hash(digest: HashWriter, name: str, contents: bytes) -> None:
    """Add one unambiguous named byte sequence to an input fingerprint."""

    name_bytes = name.encode()
    digest.update(len(name_bytes).to_bytes(8, "big"))
    digest.update(name_bytes)
    digest.update(len(contents).to_bytes(8, "big"))
    digest.update(contents)


def controlled_prompt_source(tree: MemoryTree) -> MemoryTree:
    """Select source files which can affect assembled prompt variants."""

    roots = frozenset({"instructions", "output-style"})
    expressions = frozenset({Path("agent-instructions.nix"), Path("output-styles.nix")})
    return MemoryTree(
        tuple(
            entry
            for entry in tree.files
            if entry.relative in expressions
            or (entry.relative.parts and entry.relative.parts[0] in roots)
        )
    )
