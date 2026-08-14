"""Deterministic repository verification capability."""

from dataclasses import dataclass, replace
from pathlib import Path

from .errors import ConformanceError
from .models import (
    Fixture,
    InstancePaths,
    NetworkAccess,
    ProcessCapabilities,
    ProcessInvocation,
    VerificationCommand,
    VerificationKind,
    VerificationResult,
)
from .ports import ProcessRunner
from .workspace import clean_environment


@dataclass(eq=True)
class WorkspacePreparationCommandError(ConformanceError):
    name: str
    return_code: int
    stderr: Path

    def __str__(self) -> str:
        return (
            f"workspace preparation {self.name!r} failed with exit "
            f"{self.return_code}; see {self.stderr}"
        )


class CommandVerifier:
    """Execute the typed verification commands declared by a fixture."""

    def __init__(self, runner: ProcessRunner) -> None:
        self._runner = runner

    def verify(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> tuple[VerificationResult, ...]:
        return tuple(
            self._check(fixture, check, instance, artefacts, index)
            for index, check in enumerate(fixture.verification)
        )

    def _check(
        self,
        fixture: Fixture,
        check: VerificationCommand,
        instance: InstancePaths,
        artefacts: Path,
        index: int,
    ) -> VerificationResult:
        """Run one check, quarantining a gate which fails and then passes."""

        first = self._attempt(fixture, check, instance, artefacts, f"{index}")
        if first.passed or check.kind is not VerificationKind.GATE:
            return first

        retried = self._attempt(fixture, check, instance, artefacts, f"{index}.retry")
        return replace(retried, flaky=retried.passed)

    def _attempt(
        self,
        fixture: Fixture,
        check: VerificationCommand,
        instance: InstancePaths,
        artefacts: Path,
        attempt: str,
    ) -> VerificationResult:
        stdout = artefacts / f"verification-{attempt}.stdout"
        stderr = artefacts / f"verification-{attempt}.stderr"
        process = self._runner.run(
            ProcessInvocation(
                command=check.command,
                cwd=instance.workspace / check.working_directory,
                environment=clean_environment(fixture.environment_path)
                | {
                    "HOME": str(instance.control / "verification-home"),
                    "TMPDIR": str(instance.candidate_temp),
                    "XDG_CACHE_HOME": str(instance.candidate_cache),
                },
                capabilities=ProcessCapabilities(
                    writable_paths=(
                        instance.workspace,
                        instance.control,
                        instance.candidate_cache,
                        instance.candidate_temp,
                        artefacts,
                    ),
                    network=NetworkAccess.PUBLIC,
                    readable_paths=(instance.workspace,),
                ),
                stdout=stdout,
                stderr=stderr,
            )
        )
        return VerificationResult(
            name=check.name,
            command=check.command,
            kind=check.kind,
            expected_return_code=check.expected_return_code,
            return_code=process.return_code,
            stdout=stdout,
            stderr=stderr,
        )


class CommandWorkspacePreparer:
    """Install dependencies declared by a fixture in its isolated checkout."""

    def __init__(self, runner: ProcessRunner) -> None:
        self._runner = runner

    def prepare(
        self,
        fixture: Fixture,
        instance: InstancePaths,
        artefacts: Path,
    ) -> None:
        for index, command in enumerate(fixture.preparation):
            stdout = artefacts / f"preparation-{index}.stdout"
            stderr = artefacts / f"preparation-{index}.stderr"
            result = self._runner.run(
                ProcessInvocation(
                    command=command.command,
                    cwd=instance.workspace / command.working_directory,
                    environment=clean_environment(fixture.environment_path)
                    | {
                        "HOME": str(instance.control / "preparation-home"),
                        "TMPDIR": str(instance.candidate_temp),
                        "XDG_CACHE_HOME": str(instance.candidate_cache),
                    },
                    capabilities=ProcessCapabilities(
                        writable_paths=(
                            instance.workspace,
                            instance.control,
                            instance.candidate_cache,
                            instance.candidate_temp,
                        ),
                        network=NetworkAccess.PUBLIC,
                    ),
                    stdout=stdout,
                    stderr=stderr,
                )
            )
            if not result.succeeded:
                raise WorkspacePreparationCommandError(
                    command.name, result.return_code, stderr
                )
