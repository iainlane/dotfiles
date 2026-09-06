"""Linux process isolation implemented with Bubblewrap."""

from dataclasses import dataclass
from pathlib import Path

from ..errors import ConformanceError
from ..models import NetworkAccess, ProcessInvocation, ProcessResult
from ..ports import IsolatedChildProcesses, ProcessSession
from ..process import SandboxInfoPipe


@dataclass(eq=True)
class IsolationEmptyFileWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return (
            f"could not write the empty file {self.destination} used to hide "
            f"regular files: {self.cause}"
        )


class LinuxProcessRunner:
    """Map process capabilities to Bubblewrap arguments and execute them."""

    def __init__(
        self,
        bubblewrap_program: str,
        processes: IsolatedChildProcesses,
    ) -> None:
        self._bubblewrap_program = bubblewrap_program
        self._processes = processes

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        with SandboxInfoPipe.open(invocation.command) as sandbox:
            return self._processes.run(
                invocation,
                self._command(invocation, sandbox),
                sandbox,
            )

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        """Run a bidirectional protocol through the same Bubblewrap sandbox."""

        with SandboxInfoPipe.open(invocation.command) as sandbox:
            return self._processes.run_interactive(
                invocation,
                self._command(invocation, sandbox),
                session,
                sandbox,
            )

    def _command(
        self,
        invocation: ProcessInvocation,
        sandbox: SandboxInfoPipe,
    ) -> tuple[str, ...]:
        return bubblewrap_command(
            self._bubblewrap_program,
            invocation,
            sandbox.write_descriptor,
            self._empty_file(invocation),
        )

    def _empty_file(self, invocation: ProcessInvocation) -> Path:
        """Create the file bound over each hidden regular file."""

        empty = invocation.stdout.with_suffix(".hidden")
        try:
            empty.parent.mkdir(parents=True, exist_ok=True)
            empty.write_bytes(b"")
        except OSError as error:
            raise IsolationEmptyFileWriteError(empty, error) from error

        return empty


def bubblewrap_command(
    bubblewrap_program: str,
    invocation: ProcessInvocation,
    info_descriptor: int,
    empty_file: Path,
) -> tuple[str, ...]:
    system_paths = tuple(
        Path(path)
        for path in (
            "/bin",
            "/etc/group",
            "/etc/hosts",
            "/etc/localtime",
            "/etc/nsswitch.conf",
            "/etc/passwd",
            "/etc/resolv.conf",
            "/etc/ssl",
            "/lib",
            "/lib64",
            "/nix/store",
            "/run/current-system",
            "/usr",
        )
    )
    readable_paths = tuple(
        path.resolve() for path in invocation.capabilities.readable_paths
    )
    writable_paths = tuple(
        path.resolve() for path in invocation.capabilities.writable_paths
    )
    writable_files = tuple(
        path.resolve() for path in invocation.capabilities.writable_files
    )
    unix_sockets = tuple(
        (path.resolve(), path) for path in invocation.capabilities.unix_sockets
    )
    hidden_paths = tuple(
        path.resolve() for path in invocation.capabilities.hidden_paths
    )
    command = [
        bubblewrap_program,
        "--die-with-parent",
        # Bwrap reports the pid it calls setsid() in here, which is therefore
        # the process group id of everything inside the sandbox.
        # ProcessSupervisor signals that group, so this descriptor is what
        # makes a graceful stop possible at all.
        "--info-fd",
        str(info_descriptor),
        # Without a new session, a TIOCSTI ioctl from the sandboxed process
        # could inject characters into the controlling terminal and escape
        # supervision. Do not remove this without an equivalent mitigation.
        "--new-session",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--tmpfs",
        "/",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
    ]
    # Bwrap creates the parent directories of every mount destination in the
    # private root, so the binds below need no preparatory --dir arguments.
    for path in system_paths:
        command.extend(("--ro-bind-try", str(path), str(path)))
    for path in readable_paths:
        command.extend(("--ro-bind", str(path), str(path)))
    for path in writable_paths:
        command.extend(("--bind", str(path), str(path)))
    for path in writable_files:
        command.extend(("--bind", str(path), str(path)))
    for source, destination in unix_sockets:
        command.extend(("--ro-bind", str(source), str(destination)))
    # Bwrap processes bind operations in argument order, so shadowing each
    # hidden path after every other bind above hides it even when it is nested
    # inside a writable or readable path. A tmpfs can only be mounted on a
    # directory, so a hidden regular file gets an empty read-only bind.
    for path in hidden_paths:
        if path.is_file():
            command.extend(("--ro-bind", str(empty_file), str(path)))
            continue

        command.extend(("--tmpfs", str(path)))
    if invocation.capabilities.network is NetworkAccess.NONE:
        command.append("--unshare-net")
    # Resolve the working directory to match the bind paths above. A symlink
    # in the unresolved path may not exist inside the sandbox.
    command.extend(
        ("--chdir", str(invocation.cwd.resolve()), "--", *invocation.command)
    )
    return tuple(command)
