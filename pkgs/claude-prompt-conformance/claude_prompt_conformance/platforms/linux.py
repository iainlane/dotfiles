"""Linux process isolation implemented with Bubblewrap."""

from pathlib import Path

from ..models import NetworkAccess, ProcessInvocation, ProcessResult
from ..ports import ProcessSession
from ..process import ProcessSupervisor, SandboxInfoPipe


class LinuxProcessRunner:
    """Map process capabilities to Bubblewrap arguments and execute them."""

    def __init__(self, bubblewrap_program: str, processes: ProcessSupervisor) -> None:
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
        )


def bubblewrap_command(
    bubblewrap_program: str,
    invocation: ProcessInvocation,
    info_descriptor: int,
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
    exposed_paths = (
        readable_paths
        + writable_paths
        + tuple(path.parent for path in writable_files)
        + tuple(destination for _, destination in unix_sockets)
        + hidden_paths
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
    for path in mount_parent_directories(system_paths + exposed_paths):
        command.extend(("--dir", str(path)))
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
    # Bwrap processes bind operations in argument order, so mounting an empty
    # tmpfs over each hidden path after every other bind above shadows it,
    # even when it is nested inside a writable or readable path.
    for path in hidden_paths:
        command.extend(("--tmpfs", str(path)))
    if invocation.capabilities.network is NetworkAccess.NONE:
        command.append("--unshare-net")
    command.extend(("--chdir", str(invocation.cwd), "--", *invocation.command))
    return tuple(command)


def mount_parent_directories(paths: tuple[Path, ...]) -> tuple[Path, ...]:
    """Create parents for explicit capabilities in the private root."""

    directories: set[Path] = set()
    for path in paths:
        parent = path.parent
        while parent != Path("/"):
            directories.add(parent)
            parent = parent.parent

    return tuple(sorted(directories, key=lambda path: (len(path.parts), str(path))))
