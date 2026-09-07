"""Pin the run's program closure against garbage collection while it runs.

Startup reads every document input into memory, but the programs a run spawns
throughout its lifetime, such as the pinned clients and the evidence MCP
server, are executed from the Nix store on every process start. Indirect
garbage-collector roots on the store paths the configuration names pin those
closures.

The user-side links live under `XDG_RUNTIME_DIR`, which the operating system
clears when the session ends, or under the per-user temporary directory where
there is no such variable, as on macOS. `nix-store --add-root` names the first
link as asked and numbers the rest, so one run owns every link whose name
begins with its identifier. Releasing the roots is deleting those links, and
Nix prunes the then-dangling automatic roots at its next collection. A run
killed before it can clean up leaves its links behind, so entering the
directory sweeps the links of processes which no longer exist.
"""

import os
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
    """Return the directory the closure-root links live in.

    This is `XDG_RUNTIME_DIR`, or the per-user temporary directory when that
    variable is unset.
    """

    runtime = environment.get("XDG_RUNTIME_DIR")
    if runtime:
        return Path(runtime) / "claude-prompt-conformance"
    return Path(tempfile.gettempdir()) / "claude-prompt-conformance"


def nix_store_program(nix_program: str) -> str:
    """Locate nix-store beside the configured nix program."""

    return str(Path(nix_program).with_name("nix-store"))


def sweep_dead_roots(directory: Path) -> None:
    """Delete the links of runs whose process no longer exists."""

    for link in directory.glob("run-*"):
        identifier, _, _ = link.name.removeprefix("run-").partition("-")
        try:
            os.kill(int(identifier), 0)
        except ValueError:
            continue
        except ProcessLookupError:
            link.unlink(missing_ok=True)
        except PermissionError:
            continue
        except OSError:
            continue


def _execute(command: tuple[str, ...]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, capture_output=True, check=False)


@contextmanager
def pinned_closure(
    paths: tuple[Path, ...],
    program: str,
    directory: Path,
    identifier: str,
    runner: ClosureRootRunner = _execute,
    store: Path = _STORE,
) -> Generator[Path | None]:
    """Root the run's store closures while it may still spawn its programs.

    A path outside the store, such as one a test assembles, is left alone. A
    configuration made entirely of such paths needs no root and gets none.
    """

    rooted = tuple(dict.fromkeys(path for path in paths if store in path.parents))
    if not rooted:
        yield None
        return

    link = directory / identifier
    try:
        directory.mkdir(parents=True, exist_ok=True)
        sweep_dead_roots(directory)
        result = runner(
            (program, "--add-root", str(link), "-r", *(str(path) for path in rooted))
        )
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
        for created in directory.glob(f"{identifier}*"):
            created.unlink(missing_ok=True)
