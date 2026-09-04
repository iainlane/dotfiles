"""Nix-backed construction of immutable prompt variants."""

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import msgspec

from .errors import ConformanceError
from .inputs import RuntimeInputs
from .models import (
    NetworkAccess,
    ProcessCapabilities,
    ProcessInvocation,
    PromptProposal,
    RuntimeConfiguration,
)
from .ports import ProcessRunner
from .protocols.nix import NixBuildResult
from .run_store import refresh_execution
from .storage import (
    RetainedPathUnsafeError,
    atomic_write,
    directory_exists,
    ensure_directory,
    remove_directory,
)


@dataclass(eq=True)
class PromptVariantBuildError(ConformanceError):
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return (
            f"Nix could not build the prompt variant with exit {self.return_code}; "
            f"see {self.stderr}"
        )


@dataclass(eq=True)
class PromptVariantArtefactError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return (
            f"could not prepare prompt variant artefacts at {self.path}: {self.cause}"
        )


@dataclass(eq=True)
class PromptVariantMetadataDecodeError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"Nix returned invalid prompt variant metadata at {self.source}: {self.cause}"


@dataclass(eq=True)
class PromptVariantResultCountError(ConformanceError):
    actual_count: int

    def __str__(self) -> str:
        return f"Nix returned {self.actual_count} prompt variant build results"


@dataclass(eq=True)
class PromptVariantOutputsError(ConformanceError):
    actual_outputs: tuple[str, ...]

    def __str__(self) -> str:
        return f"Nix returned prompt variant outputs {self.actual_outputs!r}"


class NixPromptVariantBuilder:
    """Apply a proposal through the repository's Nix prompt constructor."""

    def __init__(self, runner: ProcessRunner) -> None:
        self._runner = runner

    def build(
        self,
        configuration: RuntimeConfiguration,
        proposal: PromptProposal,
        artefacts: Path,
        root: Path,
    ) -> RuntimeConfiguration:
        if proposal.no_change:
            return configuration

        retained = artefacts / "inputs" / "configuration.json"
        identity = artefacts / ".proposal-sha256"
        if directory_exists(root, artefacts) and identity.is_symlink():
            raise RetainedPathUnsafeError(identity)
        identity_digest = hashlib.sha256()
        identity_digest.update(msgspec.json.encode(proposal))
        identity_digest.update(
            RuntimeInputs.load(configuration.source).fingerprint().encode()
        )
        proposal_digest = identity_digest.hexdigest()
        try:
            reusable = retained.is_file() and identity.read_text() == proposal_digest
        except FileNotFoundError:
            reusable = False
        except OSError as error:
            raise PromptVariantArtefactError(identity, error) from error
        if reusable:
            inputs = RuntimeInputs.load(retained)
            runtime = inputs.reuse_materialised(artefacts / "inputs")
            return refresh_execution(runtime, configuration).configuration

        try:
            remove_directory(root, artefacts)
            ensure_directory(root, artefacts)
        except OSError as error:
            raise PromptVariantArtefactError(artefacts, error) from error
        patch = artefacts / "prompt.patch"
        try:
            patch.write_text(proposal.patch)
        except OSError as error:
            raise PromptVariantArtefactError(patch, error) from error
        stdout = artefacts / "nix-variant.json"
        stderr = artefacts / "nix-variant.stderr"
        out_link = artefacts / "nix-result"
        expression = nix_expression(configuration, patch)
        result = self._runner.run(
            ProcessInvocation(
                command=(
                    configuration.variant.nix_program,
                    "build",
                    "--impure",
                    "--out-link",
                    str(out_link),
                    "--json",
                    "--expr",
                    expression,
                ),
                cwd=artefacts,
                environment={"PATH": "", "TMPDIR": str(artefacts)},
                capabilities=ProcessCapabilities(
                    writable_paths=(artefacts,),
                    readable_paths=(
                        configuration.source.parent,
                        configuration.variant.nixpkgs,
                        configuration.variant.prompt_environment,
                        configuration.variant.prompt_source,
                        patch,
                    ),
                    network=NetworkAccess.NONE,
                    unix_sockets=(Path("/nix/var/nix/daemon-socket/socket"),),
                ),
                stdout=stdout,
                stderr=stderr,
            )
        )
        if not result.succeeded:
            raise PromptVariantBuildError(result.return_code, stderr)

        output = nix_output_path(stdout)
        runtime = RuntimeInputs.load(output / "configuration.json").materialise(
            artefacts / "inputs"
        )
        retained_configuration = refresh_execution(runtime, configuration).configuration
        try:
            atomic_write(root, identity, proposal_digest.encode())
        except OSError as error:
            raise PromptVariantArtefactError(identity, error) from error
        try:
            out_link.unlink()
        except OSError as error:
            raise PromptVariantArtefactError(out_link, error) from error
        return retained_configuration


def nix_expression(configuration: RuntimeConfiguration, patch: Path) -> str:
    """Construct a Nix expression that copies the variant inputs into the store.

    Nixpkgs is imported from its existing store path and is not copied.
    """

    # `builtins.path` copies the argument and returns a store path whose hash
    # covers the contents, so the variant derivation is keyed on the prompt's
    # contents, and the build reads its sources from the store. The store name
    # is fixed per argument so that a run store and a Nix store yield the same
    # path for the same contents.
    inputs = {
        "baseConfiguration": ("configuration.json", configuration.source),
        "expression": ("variant.nix", configuration.variant.expression),
        "patch": ("prompt.patch", patch),
        "promptEnvironment": (
            "prompt-environment.nix",
            configuration.variant.prompt_environment,
        ),
        "promptSource": ("prompt-source", configuration.variant.prompt_source),
    }
    stored = {
        argument: (
            "builtins.path { "
            f"name = {json.dumps(name)}; "
            f"path = {json.dumps(str(path.resolve()))}; "
            "}"
        )
        for argument, (name, path) in inputs.items()
    }
    # Nixpkgs is a store path already and is only imported, so a second copy
    # would rehash the whole tree for no change in what the build sees.
    nixpkgs = json.dumps(str(configuration.variant.nixpkgs.resolve()))
    return (
        f"let pkgs = import {nixpkgs} {{}}; "
        f"in import ({stored['expression']}) {{ "
        f"inherit pkgs; "
        f"baseConfiguration = {stored['baseConfiguration']}; "
        f"patch = {stored['patch']}; "
        f"promptEnvironment = {stored['promptEnvironment']}; "
        f"promptSource = {stored['promptSource']}; "
        "}"
    )


def nix_output_path(stdout: Path) -> Path:
    """Read the sole output path from `nix build --json`."""

    try:
        value = msgspec.json.decode(
            stdout.read_bytes(), type=tuple[NixBuildResult, ...]
        )
    except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
        raise PromptVariantMetadataDecodeError(stdout, error) from error

    if len(value) != 1:
        raise PromptVariantResultCountError(len(value))

    (item,) = value
    outputs = tuple(sorted(item.outputs))
    if outputs != ("out",):
        raise PromptVariantOutputsError(outputs)

    return Path(item.outputs["out"])
