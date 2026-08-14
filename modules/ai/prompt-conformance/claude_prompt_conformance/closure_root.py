"""Pin the run's program closure against garbage collection while it runs.

Startup reads every document input into memory, but the programs a run spawns
throughout its lifetime, such as the pinned clients and the evidence MCP
server, are executed from the Nix store on every process start. An indirect
garbage-collector root on the runtime configuration pins that whole closure.

The root's user-side link lives in a session-scoped directory: releasing the
root is deleting the link, the operating system deletes the directory when
the session ends, and Nix prunes the then-dangling automatic root at its next
collection. A run that dies without cleaning up therefore pins nothing beyond
the session.
"""

import subprocess
import tempfile
from collections.abc import Callable, Generator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from .errors import ConformanceError

_STORE = Path("/nix/store")

type ClosureRootRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[bytes]]


@dataclass(eq=True)
class ClosureRootCreateError(ConformanceError):
    link: Path
    detail: str

    def __str__(self) -> str:
        return f"could not pin the runtime closure at {self.link}: {self.detail}"


def runtime_directory(environment: Mapping[str, str]) -> Path:
    """Return the session-scoped directory which holds closure root links."""

    runtime = environment.get("XDG_RUNTIME_DIR")
    if runtime:
        return Path(runtime) / "claude-prompt-conformance"
    return Path(tempfile.gettempdir()) / "claude-prompt-conformance"


def nix_store_program(nix_program: str) -> str:
    """Locate nix-store beside the configured nix program."""

    return str(Path(nix_program).with_name("nix-store"))


def _execute(command: tuple[str, ...]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, capture_output=True, check=False)


@contextmanager
def pinned_closure(
    configuration: Path,
    program: str,
    directory: Path,
    identifier: str,
    runner: ClosureRootRunner = _execute,
    store: Path = _STORE,
) -> Generator[Path | None]:
    """Root the configuration's closure while the run may spawn its programs.

    A configuration outside the store, such as one assembled by a test, needs
    no root and gets none.
    """

    if store not in configuration.parents:
        yield None
        return

    link = directory / identifier
    try:
        directory.mkdir(parents=True, exist_ok=True)
        result = runner((program, "--add-root", str(link), "-r", str(configuration)))
    except OSError as error:
        raise ClosureRootCreateError(link, str(error)) from error
    if result.returncode != 0:
        raise ClosureRootCreateError(
            link,
            result.stderr.decode(errors="replace").strip(),
        )

    try:
        yield link
    finally:
        link.unlink(missing_ok=True)
