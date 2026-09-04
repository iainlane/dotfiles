import asyncio
import errno
import os
import select
import signal
import subprocess
import threading
import time
import weakref
from contextlib import ExitStack
from dataclasses import dataclass, field
from enum import Enum, auto
from pathlib import Path
from threading import Condition
from typing import IO, Self

import msgspec

from .errors import ConformanceError, ProcessExecutionError
from .models import ProcessInvocation, ProcessOutputRecord, ProcessResult
from .ports import CancellationSignal, ProcessSession


@dataclass(eq=True)
class ProcessStartError(ProcessExecutionError):
    command: tuple[str, ...]
    errno: int | None
    filename: str | None

    def __str__(self) -> str:
        return f"could not start {command_program(self.command)} (errno {self.errno})"


@dataclass(eq=True)
class ProcessOutputDirectoryCreateError(ProcessExecutionError):
    command: tuple[str, ...]
    directory: Path
    errno: int | None

    def __str__(self) -> str:
        return (
            f"could not create output directory {self.directory} for "
            f"{command_program(self.command)} (errno {self.errno})"
        )


@dataclass(eq=True)
class ProcessStandardOutputOpenError(ProcessExecutionError):
    command: tuple[str, ...]
    output: Path
    errno: int | None

    def __str__(self) -> str:
        return (
            f"could not open standard output {self.output} for "
            f"{command_program(self.command)} (errno {self.errno})"
        )


@dataclass(eq=True)
class ProcessStandardErrorOpenError(ProcessExecutionError):
    command: tuple[str, ...]
    output: Path
    errno: int | None

    def __str__(self) -> str:
        return (
            f"could not open standard error {self.output} for "
            f"{command_program(self.command)} (errno {self.errno})"
        )


@dataclass(eq=True)
class ProcessStandardInputOpenError(ProcessExecutionError):
    command: tuple[str, ...]
    source: Path
    errno: int | None

    def __str__(self) -> str:
        return (
            f"could not open standard input {self.source} for "
            f"{command_program(self.command)} (errno {self.errno})"
        )


@dataclass(eq=True)
class ProcessWaitError(ProcessExecutionError):
    command: tuple[str, ...]
    errno: int | None

    def __str__(self) -> str:
        program = command_program(self.command)
        return f"could not collect {program}'s exit status (errno {self.errno})"


@dataclass(eq=True)
class ProcessSecretWriteError(ProcessExecutionError):
    command: tuple[str, ...]
    environment_variable: str
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return (
            f"could not provide {self.environment_variable} to {program}: {self.cause}"
        )


@dataclass(eq=True)
class ProcessSecretPipeCreateError(ProcessExecutionError):
    command: tuple[str, ...]
    environment_variable: str
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return (
            f"could not create {self.environment_variable} for {program}: {self.cause}"
        )


@dataclass(eq=True)
class ProcessSecretPipeOpenError(ProcessExecutionError):
    command: tuple[str, ...]
    environment_variable: str
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return f"could not open {self.environment_variable} for {program}: {self.cause}"


@dataclass(eq=True)
class ProcessSecretPipeCloseError(ProcessExecutionError):
    command: tuple[str, ...]
    environment_variable: str
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return (
            f"could not close {self.environment_variable} for {program}: {self.cause}"
        )


@dataclass(eq=True)
class ProcessSandboxInfoPipeCreateError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return f"could not create the sandbox report pipe for {program}: {self.cause}"


@dataclass(eq=True)
class ProcessSandboxInfoReadError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        program = command_program(self.command)
        return f"could not read the sandbox report for {program}: {self.cause}"


@dataclass(eq=True)
class ProcessSandboxInfoInvalidError(ProcessExecutionError):
    command: tuple[str, ...]
    document: bytes

    def __str__(self) -> str:
        program = command_program(self.command)
        return (
            f"the sandbox for {program} reported {self.document!r} instead of "
            "the process group to signal"
        )


@dataclass(eq=True)
class ProcessReaperStartError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: RuntimeError

    def __str__(self) -> str:
        return f"could not start the exit monitor for {command_program(self.command)}"


@dataclass(eq=True)
class ProcessOutputReaderStartError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: RuntimeError

    def __str__(self) -> str:
        return f"could not start the output reader for {command_program(self.command)}"


@dataclass(eq=True)
class ProcessOutputWakeupCreateError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        return f"could not create the output wakeup for {command_program(self.command)}"


@dataclass(eq=True)
class ProcessOutputWakeupWriteError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        return f"could not wake the output reader for {command_program(self.command)}"


@dataclass(eq=True)
class ProcessOutputBufferError(ProcessExecutionError):
    command: tuple[str, ...]

    def __str__(self) -> str:
        return f"could not buffer output from {command_program(self.command)}"


@dataclass(eq=True)
class ProcessOutputRecordLimitError(ProcessExecutionError):
    command: tuple[str, ...]
    maximum_bytes: int

    def __str__(self) -> str:
        return (
            f"{command_program(self.command)} produced an output record larger than "
            f"{self.maximum_bytes} bytes"
        )


@dataclass(eq=True)
class ProcessGroupStopError(ProcessExecutionError):
    command: tuple[str, ...]
    process_id: int

    def __str__(self) -> str:
        return (
            f"process group {self.process_id} for {command_program(self.command)} "
            "remained after SIGKILL"
        )


@dataclass(eq=True)
class ProcessDeadlineExceededError(ProcessExecutionError):
    command: tuple[str, ...]
    deadline_seconds: float

    def __str__(self) -> str:
        return (
            f"{command_program(self.command)} did not finish within "
            f"{self.deadline_seconds:g} seconds"
        )


@dataclass(eq=True)
class MissingProcessStatusError(ProcessExecutionError):
    command: tuple[str, ...]

    def __str__(self) -> str:
        return f"{command_program(self.command)} produced no exit status"


@dataclass(eq=True)
class ProcessInteractiveInputWriteError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        return f"could not write interactive input to {self.command[0]}: {self.cause}"


@dataclass(eq=True)
class ProcessInteractiveInputClosedError(ProcessExecutionError):
    command: tuple[str, ...]

    def __str__(self) -> str:
        return f"{self.command[0]} requested input after its interactive stream closed"


@dataclass(eq=True)
class ProcessInteractiveOutputReadError(ProcessExecutionError):
    command: tuple[str, ...]
    cause: OSError

    def __str__(self) -> str:
        return f"could not read interactive output from {self.command[0]}: {self.cause}"


@dataclass(eq=True)
class ProcessTranscriptWriteError(ProcessExecutionError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not record process output at {self.destination}: {self.cause}"


@dataclass(eq=True)
class ProcessInteractiveInputPipeMissingError(ProcessExecutionError):
    command: tuple[str, ...]

    def __str__(self) -> str:
        return f"{self.command[0]} has no stdin pipe for interactive input"


@dataclass(eq=True)
class ProcessInteractiveOutputPipeMissingError(ProcessExecutionError):
    command: tuple[str, ...]

    def __str__(self) -> str:
        return f"{self.command[0]} has no stdout pipe for interactive output"


@dataclass(eq=True)
class ProcessInteractiveInputConflictError(ProcessExecutionError):
    source: Path

    def __str__(self) -> str:
        return f"interactive process input conflicts with the static input at {self.source}"


def command_program(command: tuple[str, ...]) -> str:
    """Return the executable named by a process-boundary command."""

    match command:
        case (program, *_):
            return program
        case _:
            return "an empty command"


class RunCancelled(asyncio.CancelledError):
    """Signal that the suite cancelled an active process."""


_DEFAULT_DEADLINE_SECONDS = 2 * 60 * 60
_STOP_SIGNAL_SECONDS = 2.0
# A user's interrupt deserves shorter grace windows than a deadline stop: the
# processes' work is being abandoned, not collected.
_CANCEL_SIGNAL_SECONDS = 0.75
_STOP_POLL_SECONDS = 0.05
_TEARDOWN_SECONDS = 3 * _STOP_SIGNAL_SECONDS


def _discard_descriptor(descriptor: int) -> None:
    try:
        os.close(descriptor)
    except OSError:
        pass


@dataclass(eq=False)
class _ManagedProcess:
    process: subprocess.Popen[bytes]
    command: tuple[str, ...]
    sandbox_group: int | None = None
    lifecycle: threading.Lock = field(default_factory=threading.Lock)
    stop: threading.Lock = field(default_factory=threading.Lock)
    finished: threading.Event = field(default_factory=threading.Event)
    return_code: int | None = None
    error: ProcessWaitError | None = None
    cleanup_error: ProcessGroupStopError | None = None
    output_channel: "_OutputChannel | None" = None

    @property
    def group(self) -> int:
        """Return the process group that carries the command being run."""

        # A sandbox that starts its own session leaves the outer group holding
        # nothing but the sandbox program, so signals sent there never reach
        # the command; the group the sandbox reports holds the command itself.
        if self.sandbox_group is None:
            return self.process.pid
        return self.sandbox_group


@dataclass(frozen=True)
class _ProcessDeadline:
    """Bound one invocation so a stalled child cannot detain the run."""

    command: tuple[str, ...]
    seconds: float
    expires_at: float

    @classmethod
    def start(
        cls,
        command: tuple[str, ...],
        seconds: float | None,
    ) -> "_ProcessDeadline":
        bound = _DEFAULT_DEADLINE_SECONDS if seconds is None else seconds
        return cls(command, bound, time.monotonic() + bound)

    def remaining(self) -> float:
        return max(0.0, self.expires_at - time.monotonic())

    def exceeded(self) -> ProcessDeadlineExceededError:
        return ProcessDeadlineExceededError(self.command, self.seconds)


_SANDBOX_INFO_MAXIMUM_BYTES = 64 * 1024


class _SandboxInfo(msgspec.Struct, rename={"child_pid": "child-pid"}):
    """The part of a sandbox's information document the supervisor acts on."""

    child_pid: int


@dataclass(eq=False)
class SandboxInfoPipe:
    """Carry a sandbox's information document back to the supervisor."""

    read_descriptor: int
    write_descriptor: int

    @classmethod
    def open(cls, command: tuple[str, ...]) -> Self:
        try:
            read_descriptor, write_descriptor = os.pipe()
        except OSError as error:
            raise ProcessSandboxInfoPipeCreateError(command, error) from error

        return cls(read_descriptor, write_descriptor)

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close_write(self) -> None:
        """Drop the supervisor's writer so the sandbox's own close ends the read."""

        _discard_descriptor(self.write_descriptor)
        self.write_descriptor = -1

    def close(self) -> None:
        for descriptor in (self.read_descriptor, self.write_descriptor):
            if descriptor >= 0:
                _discard_descriptor(descriptor)

        self.read_descriptor = -1
        self.write_descriptor = -1

    def read_group(
        self,
        command: tuple[str, ...],
        deadline: _ProcessDeadline,
    ) -> int | None:
        """Return the process group the sandbox reported, if it started one."""

        document = self._read_document(command, deadline)
        self.close()
        if not document:
            # A sandbox which fails before it creates its session reports
            # nothing, and then the outer group is the only one left to signal.
            return None

        try:
            info = msgspec.json.decode(document, type=_SandboxInfo)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise ProcessSandboxInfoInvalidError(command, document) from error

        return info.child_pid

    def _read_document(
        self,
        command: tuple[str, ...],
        deadline: _ProcessDeadline,
    ) -> bytes:
        document = bytearray()
        try:
            readiness = select.poll()
            readiness.register(self.read_descriptor, select.POLLIN)
            while len(document) <= _SANDBOX_INFO_MAXIMUM_BYTES:
                available = deadline.remaining()
                if available == 0 or not readiness.poll(available * 1_000):
                    raise deadline.exceeded()
                chunk = os.read(self.read_descriptor, 4096)
                if not chunk:
                    break
                document.extend(chunk)
        except OSError as error:
            raise ProcessSandboxInfoReadError(command, error) from error

        return bytes(document)


type _OutputReaderError = (
    ProcessInteractiveOutputReadError
    | ProcessTranscriptWriteError
    | ProcessOutputBufferError
    | ProcessOutputRecordLimitError
)


class _OutputEvent(Enum):
    LEADER_FINISHED = auto()
    STOPPED = auto()


_OUTPUT_STOP = b"S"
_OUTPUT_DRAIN = b"D"
_OUTPUT_RECORD_MAXIMUM_BYTES = 16 * 1024 * 1024


@dataclass
class _OutputBuffer:
    command: tuple[str, ...]
    value: bytearray = field(default_factory=bytearray)

    def extend(self, chunk: bytes) -> tuple[bytes, ...]:
        self.value.extend(chunk)
        records: list[bytes] = []
        boundary = self.value.find(b"\n")
        while boundary >= 0:
            record_size = boundary + 1
            if record_size > _OUTPUT_RECORD_MAXIMUM_BYTES:
                raise ProcessOutputRecordLimitError(
                    self.command,
                    _OUTPUT_RECORD_MAXIMUM_BYTES,
                )
            records.append(bytes(self.value[:record_size]))
            del self.value[:record_size]
            boundary = self.value.find(b"\n")

        if len(self.value) > _OUTPUT_RECORD_MAXIMUM_BYTES:
            raise ProcessOutputRecordLimitError(
                self.command,
                _OUTPUT_RECORD_MAXIMUM_BYTES,
            )
        return tuple(records)

    def finish(self) -> tuple[bytes, ...]:
        if not self.value:
            return ()
        record = bytes(self.value)
        self.value.clear()
        return (record,)


@dataclass
class _OutputChannel:
    """Transfer one output record with blocking backpressure and wakeable closure."""

    command: tuple[str, ...]
    wakeup: int
    condition: Condition = field(default_factory=Condition)
    record: ProcessOutputRecord | None = None
    error: _OutputReaderError | None = None
    finished: bool = False
    stopped: bool = False
    stop_error: ProcessOutputWakeupWriteError | None = None
    draining: bool = False
    leader_finished: bool = False
    leader_handled: bool = False

    def send(self, record: ProcessOutputRecord) -> bool:
        """Block for capacity, returning false when the consumer has stopped."""

        with self.condition:
            while self.record is not None and not self.stopped:
                self.condition.wait()
            if self.stopped:
                return False

            self.record = record
            self.condition.notify_all()
            return True

    def receive(
        self,
        deadline: _ProcessDeadline,
    ) -> ProcessOutputRecord | _OutputEvent | None:
        """Return the next record or a process/output completion event."""

        with self.condition:
            while (
                self.record is None
                and not self.finished
                and not self.stopped
                and (not self.leader_finished or self.leader_handled)
            ):
                remaining = deadline.remaining()
                if remaining == 0:
                    raise deadline.exceeded()
                self.condition.wait(remaining)
            if self.stopped:
                if self.stop_error is not None:
                    raise self.stop_error
                return _OutputEvent.STOPPED
            if self.leader_finished and not self.finished and not self.leader_handled:
                self.leader_handled = True
                return _OutputEvent.LEADER_FINISHED
            if self.record is not None:
                record = self.record
                self.record = None
                self.condition.notify_all()
                return record
            if self.error is not None:
                raise self.error
            return None

    def finish(self, error: _OutputReaderError | None) -> None:
        """Publish producer completion and wake the consumer."""

        with self.condition:
            self.error = error
            self.finished = True
            self.condition.notify_all()

    def stop(self) -> None:
        """Wake a producer blocked by backpressure after consumer failure."""

        with self.condition:
            if self.stopped or self.finished:
                return
            try:
                os.write(self.wakeup, _OUTPUT_STOP)
            except OSError as error:
                self.stop_error = ProcessOutputWakeupWriteError(self.command, error)
            self.stopped = True
            self.condition.notify_all()
            if self.stop_error is not None:
                raise self.stop_error

    def drain(self) -> None:
        """Read currently available output without awaiting future writers."""

        with self.condition:
            if self.stopped or self.finished or self.draining:
                return
            self.draining = True
            try:
                os.write(self.wakeup, _OUTPUT_DRAIN)
            except OSError as error:
                self.stop_error = ProcessOutputWakeupWriteError(self.command, error)
                self.stopped = True
                self.condition.notify_all()
                raise self.stop_error

    def finish_leader(self) -> None:
        """Wake the consumer when the process-group leader has exited."""

        with self.condition:
            self.leader_finished = True
            self.condition.notify_all()


_ACTIVE_SUPERVISORS: "weakref.WeakSet[ProcessSupervisor]" = weakref.WeakSet()


def kill_active_process_groups() -> None:
    """Kill every process group any live supervisor started, immediately."""

    for supervisor in tuple(_ACTIVE_SUPERVISORS):
        supervisor.kill()


class ProcessSupervisor:
    """Run isolated process groups and cancel the complete active set."""

    def __init__(self, cancellation: CancellationSignal | None = None) -> None:
        self._lock = threading.Lock()
        self._processes: set[_ManagedProcess] = set()
        self._cancelled = False
        self._cancellation: CancellationSignal = cancellation or threading.Event()
        _ACTIVE_SUPERVISORS.add(self)

    def run(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
        sandbox: SandboxInfoPipe | None = None,
    ) -> ProcessResult:
        return self._run(invocation, command, None, sandbox)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
        session: ProcessSession,
        sandbox: SandboxInfoPipe | None = None,
    ) -> ProcessResult:
        """Run a line-oriented child protocol while retaining its output."""

        if invocation.stdin is not None:
            raise ProcessInteractiveInputConflictError(invocation.stdin)

        return self._run(invocation, command, session, sandbox)

    def _run(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
        session: ProcessSession | None,
        sandbox: SandboxInfoPipe | None,
    ) -> ProcessResult:
        with self._lock:
            if self._cancelled:
                raise RunCancelled

        deadline = _ProcessDeadline.start(command, invocation.deadline_seconds)
        try:
            invocation.stdout.parent.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise ProcessOutputDirectoryCreateError(
                command,
                invocation.stdout.parent,
                error.errno,
            ) from error

        with ExitStack() as stack:
            try:
                stdout = stack.enter_context(invocation.stdout.open("wb"))
            except OSError as error:
                raise ProcessStandardOutputOpenError(
                    command,
                    invocation.stdout,
                    error.errno,
                ) from error

            try:
                stderr = stack.enter_context(invocation.stderr.open("wb"))
            except OSError as error:
                raise ProcessStandardErrorOpenError(
                    command,
                    invocation.stderr,
                    error.errno,
                ) from error

            stdin = subprocess.PIPE
            process_stdout = subprocess.PIPE
            if session is None:
                stdin_path = invocation.stdin or Path(os.devnull)
                try:
                    stdin = stack.enter_context(stdin_path.open("rb"))
                except OSError as error:
                    raise ProcessStandardInputOpenError(
                        command,
                        stdin_path,
                        error.errno,
                    ) from error
                process_stdout = stdout
            environment = dict(invocation.environment)
            inherited_files: list[tuple[str, int]] = []
            secret_writers: list[tuple[str, IO[bytes], bytes]] = []
            process: subprocess.Popen[bytes] | None = None
            managed: _ManagedProcess | None = None
            try:
                for secret in invocation.secrets:
                    try:
                        read_file, write_file = os.pipe()
                    except OSError as error:
                        raise ProcessSecretPipeCreateError(
                            command,
                            secret.environment_variable,
                            error,
                        ) from error
                    try:
                        writer = os.fdopen(write_file, "wb", buffering=0)
                    except OSError as error:
                        _discard_descriptor(read_file)
                        _discard_descriptor(write_file)
                        raise ProcessSecretPipeOpenError(
                            command,
                            secret.environment_variable,
                            error,
                        ) from error
                    except BaseException:
                        _discard_descriptor(read_file)
                        _discard_descriptor(write_file)
                        raise
                    try:
                        stack.callback(self._discard_file, writer)
                        inherited_files.append((secret.environment_variable, read_file))
                    except BaseException:
                        _discard_descriptor(read_file)
                        self._discard_file(writer)
                        raise
                    secret_writers.append(
                        (secret.environment_variable, writer, secret.value)
                    )
                    environment[secret.environment_variable] = str(read_file)

                inherited = tuple(file for _, file in inherited_files)
                if sandbox is not None:
                    inherited += (sandbox.write_descriptor,)

                try:
                    process = subprocess.Popen(
                        command,
                        cwd=invocation.cwd,
                        env=environment,
                        stdin=stdin,
                        stdout=process_stdout,
                        stderr=stderr,
                        pass_fds=inherited,
                        start_new_session=True,
                    )
                except OSError as error:
                    raise ProcessStartError(
                        command,
                        error.errno,
                        error.filename,
                    ) from error

                managed = _ManagedProcess(process, command)
                reaper = threading.Thread(
                    target=self._reap,
                    args=(managed,),
                    name=f"process-reaper-{process.pid}",
                    daemon=True,
                )
                reaper_started = False
                inherited_files_closed = False
                secret_error: ProcessSecretWriteError | None = None
                exchange_error: ConformanceError | None = None
                deadline_error: ProcessDeadlineExceededError | None = None
            except BaseException:
                self._discard_secret_read_files(inherited_files)
                if process is not None:
                    self._terminate_unmanaged(process)
                if managed is not None:
                    with self._lock:
                        self._processes.discard(managed)
                raise

            try:
                with self._lock:
                    self._processes.add(managed)
                    cancelled = self._cancelled

                try:
                    reaper.start()
                except RuntimeError as error:
                    raise ProcessReaperStartError(command, error) from error
                reaper_started = True

                self._close_secret_read_files(command, inherited_files)
                inherited_files_closed = True

                if cancelled:
                    self._stop((managed,))
                else:
                    try:
                        self._adopt_sandbox_group(managed, sandbox, deadline)
                        self._deliver_secrets(command, secret_writers, deadline)
                    except ProcessSecretWriteError as error:
                        secret_error = error
                        self._stop((managed,))
                    except ProcessDeadlineExceededError as error:
                        deadline_error = error
                        self._stop((managed,))

                    delivered = secret_error is None and deadline_error is None
                    if delivered and session is not None:
                        process_input = process.stdin
                        if process_input is None:
                            raise ProcessInteractiveInputPipeMissingError(command)
                        process_output = process.stdout
                        if process_output is None:
                            raise ProcessInteractiveOutputPipeMissingError(command)
                        stack.callback(self._discard_file, process_input)
                        stack.callback(self._discard_file, process_output)
                        try:
                            self._exchange(
                                managed,
                                session,
                                process_input,
                                process_output,
                                stdout,
                                invocation.stdout,
                                deadline,
                            )
                        except ConformanceError as error:
                            exchange_error = error
                            self._stop((managed,))

                if not managed.finished.wait(timeout=deadline.remaining()):
                    deadline_error = deadline_error or deadline.exceeded()
                    self._stop((managed,))
            except KeyboardInterrupt:
                self.cancel()
                raise
            finally:
                if not inherited_files_closed:
                    self._discard_secret_read_files(inherited_files)
                if managed.cleanup_error is None and self._group_is_running(managed):
                    self._stop((managed,))
                if managed.cleanup_error is None:
                    if not reaper_started:
                        self._reap(managed)
                    elif not managed.finished.wait(timeout=_TEARDOWN_SECONDS):
                        self._stop((managed,))
                with self._lock:
                    self._processes.discard(managed)
                if managed.cleanup_error is not None:
                    raise managed.cleanup_error

            if managed.error is not None:
                raise managed.error

            with self._lock:
                cancelled = self._cancelled
            if cancelled:
                raise RunCancelled

            if secret_error is not None:
                raise secret_error

            if exchange_error is not None:
                raise exchange_error

            if deadline_error is not None:
                raise deadline_error

            if managed.return_code is None:
                raise MissingProcessStatusError(command)

        return ProcessResult(return_code=managed.return_code)

    def _exchange(
        self,
        managed: _ManagedProcess,
        session: ProcessSession,
        process_input: IO[bytes],
        process_output: IO[bytes],
        transcript: IO[bytes],
        transcript_path: Path,
        deadline: _ProcessDeadline,
    ) -> None:
        command = managed.command
        try:
            wakeup_read, wakeup_write = os.pipe()
        except OSError as error:
            raise ProcessOutputWakeupCreateError(command, error) from error
        try:
            self._exchange_with_wakeup(
                managed,
                session,
                process_input,
                process_output,
                transcript,
                transcript_path,
                wakeup_read,
                wakeup_write,
                deadline,
            )
        finally:
            _discard_descriptor(wakeup_read)
            _discard_descriptor(wakeup_write)

    def _exchange_with_wakeup(
        self,
        managed: _ManagedProcess,
        session: ProcessSession,
        process_input: IO[bytes],
        process_output: IO[bytes],
        transcript: IO[bytes],
        transcript_path: Path,
        wakeup_read: int,
        wakeup_write: int,
        deadline: _ProcessDeadline,
    ) -> None:
        command = managed.command
        try:
            channel = _OutputChannel(command, wakeup_write)
            reader = threading.Thread(
                target=self._read_output,
                args=(
                    command,
                    process_output,
                    transcript,
                    transcript_path,
                    wakeup_read,
                    channel,
                ),
                name=f"process-output-{managed.process.pid}",
                daemon=True,
            )
        except MemoryError as error:
            raise ProcessOutputBufferError(command) from error
        reader_started = False
        with managed.lifecycle:
            managed.output_channel = channel
            if managed.finished.is_set():
                channel.finish_leader()
        try:
            try:
                reader.start()
            except RuntimeError as error:
                raise ProcessOutputReaderStartError(command, error) from error
            reader_started = True

            input_closed = False
            for value in session.initial_input():
                self._write_interactive_input(command, process_input, value)

            while True:
                delivery = channel.receive(deadline)
                if delivery is None:
                    if not input_closed:
                        self._close_interactive_input(command, process_input)
                    reader.join()
                    return

                if delivery is _OutputEvent.LEADER_FINISHED:
                    if managed.cleanup_error is None:
                        self._stop((managed,))
                    if managed.cleanup_error is not None:
                        raise managed.cleanup_error
                    channel.drain()
                    continue

                if delivery is _OutputEvent.STOPPED:
                    reader.join()
                    return

                exchange = session.receive(delivery)

                for value in exchange.writes:
                    if input_closed:
                        raise ProcessInteractiveInputClosedError(command)
                    self._write_interactive_input(
                        command,
                        process_input,
                        value,
                    )
                if exchange.close_input and not input_closed:
                    self._close_interactive_input(command, process_input)
                    input_closed = True
        except BaseException:
            wakeup_error = channel.stop_error
            try:
                channel.stop()
            except ProcessOutputWakeupWriteError as error:
                wakeup_error = error
            if managed.cleanup_error is None:
                self._stop((managed,))
            wakeup_error = wakeup_error or channel.stop_error
            if reader_started and wakeup_error is None:
                reader.join()
            if managed.cleanup_error is not None:
                raise managed.cleanup_error
            if wakeup_error is not None:
                raise wakeup_error
            raise
        finally:
            with managed.lifecycle:
                if managed.output_channel is channel:
                    managed.output_channel = None

    @staticmethod
    def _read_output(
        command: tuple[str, ...],
        process_output: IO[bytes],
        transcript: IO[bytes],
        transcript_path: Path,
        wakeup: int,
        channel: _OutputChannel,
    ) -> None:
        error: _OutputReaderError | None = None
        buffered = _OutputBuffer(command)
        try:
            try:
                os.set_blocking(transcript.fileno(), False)
            except OSError as cause:
                error = ProcessTranscriptWriteError(transcript_path, cause)
                return
            try:
                readiness = select.poll()
                readiness.register(process_output.fileno(), select.POLLIN)
                readiness.register(wakeup, select.POLLIN)
            except OSError as cause:
                error = ProcessInteractiveOutputReadError(command, cause)
                return

            while True:
                if channel.draining:
                    try:
                        os.set_blocking(process_output.fileno(), False)
                        chunk = os.read(
                            process_output.fileno(),
                            _OUTPUT_RECORD_MAXIMUM_BYTES + 1,
                        )
                    except BlockingIOError:
                        chunk = b""
                    except OSError as cause:
                        error = ProcessInteractiveOutputReadError(command, cause)
                        return
                    records = (*buffered.extend(chunk), *buffered.finish())
                    ProcessSupervisor._publish_output_records(
                        records,
                        transcript,
                        transcript_path,
                        wakeup,
                        channel,
                    )
                    return

                try:
                    readable = {descriptor for descriptor, _ in readiness.poll()}
                    if wakeup in readable:
                        directive = os.read(wakeup, 1)
                        if directive == _OUTPUT_STOP:
                            return
                        continue
                    chunk = os.read(process_output.fileno(), 64 * 1024)
                except OSError as cause:
                    error = ProcessInteractiveOutputReadError(command, cause)
                    return

                if not chunk:
                    ProcessSupervisor._publish_output_records(
                        buffered.finish(),
                        transcript,
                        transcript_path,
                        wakeup,
                        channel,
                    )
                    return

                if not ProcessSupervisor._publish_output_records(
                    buffered.extend(chunk),
                    transcript,
                    transcript_path,
                    wakeup,
                    channel,
                ):
                    return
        except (
            ProcessOutputRecordLimitError,
            ProcessTranscriptWriteError,
        ) as cause:
            error = cause
        except MemoryError:
            error = ProcessOutputBufferError(command)
        finally:
            channel.finish(error)

    @staticmethod
    def _publish_output_records(
        records: tuple[bytes, ...],
        transcript: IO[bytes],
        transcript_path: Path,
        wakeup: int,
        channel: _OutputChannel,
    ) -> bool:
        for value in records:
            output = ProcessOutputRecord(value, time.monotonic())
            if not ProcessSupervisor._write_transcript(
                transcript,
                transcript_path,
                wakeup,
                channel,
                output.value,
            ):
                return False
            if not channel.send(output):
                return False
        return True

    @staticmethod
    def _write_transcript(
        transcript: IO[bytes],
        transcript_path: Path,
        wakeup: int,
        channel: _OutputChannel,
        value: bytes,
    ) -> bool:
        remaining = memoryview(value)
        draining = channel.draining
        try:
            readiness = select.poll()
            readiness.register(wakeup, select.POLLIN)
            readiness.register(transcript.fileno(), select.POLLOUT)
        except OSError as cause:
            raise ProcessTranscriptWriteError(transcript_path, cause) from cause
        while remaining:
            try:
                if not draining:
                    readable = {descriptor for descriptor, _ in readiness.poll()}
                    if wakeup in readable:
                        directive = os.read(wakeup, 1)
                        if directive == _OUTPUT_STOP:
                            return False
                        draining = True
                        continue
                written = os.write(transcript.fileno(), remaining)
                if written == 0:
                    raise OSError(errno.EIO, "transcript accepted no bytes")
            except OSError as cause:
                raise ProcessTranscriptWriteError(transcript_path, cause) from cause
            remaining = remaining[written:]
        return True

    @staticmethod
    def _close_interactive_input(
        command: tuple[str, ...],
        process_input: IO[bytes],
    ) -> None:
        try:
            process_input.close()
        except OSError as error:
            raise ProcessInteractiveInputWriteError(command, error) from error

    @staticmethod
    def _write_interactive_input(
        command: tuple[str, ...],
        process_input: IO[bytes],
        value: bytes,
    ) -> None:
        try:
            process_input.write(value)
            process_input.flush()
        except OSError as error:
            raise ProcessInteractiveInputWriteError(command, error) from error

    @staticmethod
    def _close_secret_read_files(
        command: tuple[str, ...],
        inherited_files: list[tuple[str, int]],
    ) -> None:
        failure: ProcessSecretPipeCloseError | None = None
        while inherited_files:
            environment_variable, descriptor = inherited_files.pop()
            try:
                os.close(descriptor)
            except OSError as error:
                failure = failure or ProcessSecretPipeCloseError(
                    command,
                    environment_variable,
                    error,
                )
        if failure is not None:
            raise failure

    @staticmethod
    def _discard_secret_read_files(
        inherited_files: list[tuple[str, int]],
    ) -> None:
        while inherited_files:
            _, descriptor = inherited_files.pop()
            try:
                os.close(descriptor)
            except OSError:
                continue

    @staticmethod
    def _adopt_sandbox_group(
        managed: _ManagedProcess,
        sandbox: SandboxInfoPipe | None,
        deadline: _ProcessDeadline,
    ) -> None:
        """Take on the process group a sandbox reports for its own session."""

        if sandbox is None:
            return

        sandbox.close_write()
        group = sandbox.read_group(managed.command, deadline)
        with managed.lifecycle:
            managed.sandbox_group = group

    @staticmethod
    def _discard_file(file: IO[bytes]) -> None:
        try:
            file.close()
        except OSError:
            pass

    @staticmethod
    def _deliver_secrets(
        command: tuple[str, ...],
        writers: list[tuple[str, IO[bytes], bytes]],
        deadline: _ProcessDeadline,
    ) -> None:
        for environment_variable, writer, value in writers:
            try:
                # A blocking pipe write of more than one buffer stalls until the
                # child drains it, so the deadline needs a non-blocking stream.
                descriptor = writer.fileno()
                os.set_blocking(descriptor, False)
                readiness = select.poll()
                readiness.register(descriptor, select.POLLOUT)
                remaining = memoryview(value)
                while remaining:
                    available = deadline.remaining()
                    if available == 0 or not readiness.poll(available * 1_000):
                        raise deadline.exceeded()
                    written = writer.write(remaining)
                    if written is None:
                        continue
                    if written == 0:
                        raise OSError(errno.EIO, "secret pipe accepted no bytes")
                    remaining = remaining[written:]
                writer.flush()
                writer.close()
            except OSError as error:
                raise ProcessSecretWriteError(
                    command,
                    environment_variable,
                    error,
                ) from error

    def cancel(self) -> None:
        """Interrupt active process groups, escalating when they do not exit."""

        with self._lock:
            self._cancelled = True
            self._cancellation.set()
            processes = tuple(self._processes)

        self._stop(processes, _CANCEL_SIGNAL_SECONDS)
        for managed in processes:
            self._stop_output(managed)

    def kill(self) -> None:
        """Kill every active process group at once, without escalation."""

        with self._lock:
            self._cancelled = True
            self._cancellation.set()
            processes = tuple(self._processes)

        for managed in processes:
            self._signal_group(managed, signal.SIGKILL)

    @staticmethod
    def _terminate_unmanaged(process: subprocess.Popen[bytes]) -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (PermissionError, ProcessLookupError):
            return
        try:
            process.wait()
        except OSError:
            pass

    @staticmethod
    def _reap(managed: _ManagedProcess) -> None:
        try:
            return_code = managed.process.wait()
        except OSError as error:
            wait_error = ProcessWaitError(managed.command, error.errno)
            with managed.lifecycle:
                managed.error = wait_error
                managed.finished.set()
                channel = managed.output_channel
            if channel is not None:
                channel.finish_leader()
            return

        with managed.lifecycle:
            managed.return_code = return_code
            managed.finished.set()
            channel = managed.output_channel
        if channel is not None:
            channel.finish_leader()

    @staticmethod
    def _stop_output(managed: _ManagedProcess) -> None:
        with managed.lifecycle:
            channel = managed.output_channel
        if channel is None:
            return
        try:
            channel.stop()
        except ProcessOutputWakeupWriteError:
            # The channel records and publishes the typed failure itself.
            return

    def _stop(
        self,
        processes: tuple[_ManagedProcess, ...],
        grace_seconds: float = _STOP_SIGNAL_SECONDS,
    ) -> None:
        # Ordering the per-process locks by process identifier keeps concurrent
        # teardowns of overlapping sets from deadlocking against each other.
        ordered = tuple(sorted(processes, key=lambda managed: managed.process.pid))
        with ExitStack() as stack:
            for managed in ordered:
                stack.enter_context(managed.stop)

            self._signal_running(ordered, signal.SIGINT)
            remaining = self._escalate(ordered, signal.SIGTERM, grace_seconds)
            remaining = self._escalate(remaining, signal.SIGKILL, grace_seconds)
            remaining = self._wait_until(
                remaining,
                time.monotonic() + grace_seconds,
            )
            for managed in remaining:
                with managed.lifecycle:
                    managed.cleanup_error = ProcessGroupStopError(
                        managed.command,
                        managed.group,
                    )
                    managed.finished.set()
                    channel = managed.output_channel
                if channel is not None:
                    channel.finish_leader()

    @staticmethod
    def _escalate(
        processes: tuple[_ManagedProcess, ...],
        signal_number: int,
        grace_seconds: float = _STOP_SIGNAL_SECONDS,
    ) -> tuple[_ManagedProcess, ...]:
        """Await one signal's grace window, then raise the survivors' signal."""

        remaining = ProcessSupervisor._wait_until(
            processes,
            time.monotonic() + grace_seconds,
        )
        ProcessSupervisor._signal_running(remaining, signal_number)
        return remaining

    @staticmethod
    def _signal_running(
        processes: tuple[_ManagedProcess, ...], signal_number: int
    ) -> None:
        for managed in processes:
            ProcessSupervisor._signal_group(managed, signal_number)

    @staticmethod
    def _signal_group(managed: _ManagedProcess, signal_number: int) -> None:
        try:
            os.killpg(managed.group, signal_number)
        except (PermissionError, ProcessLookupError):
            return

    @staticmethod
    def _group_is_running(managed: _ManagedProcess) -> bool:
        try:
            os.killpg(managed.group, 0)
        except (PermissionError, ProcessLookupError):
            return False
        return True

    @staticmethod
    def _wait_until(
        processes: tuple[_ManagedProcess, ...], deadline: float
    ) -> tuple[_ManagedProcess, ...]:
        remaining: list[_ManagedProcess] = []
        for managed in processes:
            managed.finished.wait(timeout=max(0.0, deadline - time.monotonic()))
            while ProcessSupervisor._group_is_running(managed):
                # The leader has gone but a descendant holds the group open, so
                # poll instead of spending the whole window on one observation.
                step = min(_STOP_POLL_SECONDS, deadline - time.monotonic())
                if step <= 0:
                    remaining.append(managed)
                    break
                time.sleep(step)
        return tuple(remaining)
