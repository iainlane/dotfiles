import errno
import os
import resource
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from enum import StrEnum
from pathlib import Path
from typing import BinaryIO, Literal

import msgspec
import pytest

import claude_prompt_conformance.process as process_runtime
from claude_prompt_conformance.claude_session import (
    ClaudeControlRequestUnsupportedError,
)
from claude_prompt_conformance.models import (
    NetworkAccess,
    ProcessCapabilities,
    ProcessExchange,
    ProcessInvocation,
    ProcessOutputRecord,
    ProcessResult,
    SecretFileDescriptor,
)
from claude_prompt_conformance.process import (
    ProcessDeadlineExceededError,
    ProcessInteractiveInputConflictError,
    ProcessOutputBufferError,
    ProcessOutputDirectoryCreateError,
    ProcessOutputRecordLimitError,
    ProcessOutputWakeupCreateError,
    ProcessSandboxInfoInvalidError,
    ProcessSecretPipeOpenError,
    ProcessSecretWriteError,
    ProcessStandardErrorOpenError,
    ProcessStandardInputOpenError,
    ProcessStandardOutputOpenError,
    ProcessStartError,
    ProcessSupervisor,
    RunCancelled,
    kill_active_process_groups,
)


@dataclass(frozen=True)
class ScriptedSession:
    def initial_input(self) -> tuple[bytes, ...]:
        return (b'{"kind":"initialize"}\n', b'{"kind":"task"}\n')

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        value = msgspec.json.decode(record.value)
        if value == {"kind": "request", "id": "refresh"}:
            return ProcessExchange(writes=(b'{"kind":"response","token":"new"}\n',))
        if value == {"kind": "result"}:
            return ProcessExchange(close_input=True)
        return ProcessExchange()


@dataclass(frozen=True)
class FailingSession:
    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        raise ClaudeControlRequestUnsupportedError("fixture_failure")


@dataclass(frozen=True)
class BackloggedFailingSession:
    release: threading.Event

    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        self.release.wait()
        raise ClaudeControlRequestUnsupportedError("fixture_failure")


@dataclass(frozen=True)
class SynchronizedFailingSession:
    barrier: threading.Barrier

    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        self.barrier.wait()
        raise ClaudeControlRequestUnsupportedError("fixture_failure")


@dataclass(frozen=True)
class SilentSession:
    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        return ProcessExchange()


@dataclass
class RecordingSession:
    records: list[ProcessOutputRecord] = field(default_factory=list)

    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        self.records.append(record)
        return ProcessExchange()


@dataclass
class DelayedSession:
    release: threading.Event
    records: list[ProcessOutputRecord] = field(default_factory=list)

    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        self.records.append(record)
        if len(self.records) == 1:
            self.release.wait()
        return ProcessExchange(close_input=len(self.records) == 2)


@dataclass(frozen=True)
class BlockingResponseSession:
    started: threading.Event
    release: threading.Event

    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        self.started.set()
        self.release.wait()
        return ProcessExchange(writes=(b'{"kind":"response"}\n',))


@dataclass(frozen=True)
class ShortWriter:
    writer: BinaryIO

    def write(self, value: bytes | memoryview) -> int:
        return self.writer.write(value[:3])

    def fileno(self) -> int:
        return self.writer.fileno()

    def flush(self) -> None:
        self.writer.flush()

    def close(self) -> None:
        self.writer.close()


type Start = Callable[[ProcessSupervisor, ProcessInvocation], ProcessResult]


def start_batch(
    supervisor: ProcessSupervisor,
    invocation: ProcessInvocation,
) -> ProcessResult:
    return supervisor.run(invocation, invocation.command)


def start_interactive(
    supervisor: ProcessSupervisor,
    invocation: ProcessInvocation,
) -> ProcessResult:
    return supervisor.run_interactive(
        invocation,
        invocation.command,
        SilentSession(),
    )


SUPERVISOR_STARTS = pytest.mark.parametrize(
    "start",
    (start_batch, start_interactive),
    ids=("batch", "interactive"),
)


class ProcessIoFailure(StrEnum):
    """Filesystem boundary which should reject a process invocation."""

    OUTPUT_DIRECTORY = "output-directory"
    STANDARD_OUTPUT = "standard-output"
    STANDARD_ERROR = "standard-error"
    STANDARD_INPUT = "standard-input"


@pytest.mark.parametrize("failure", tuple(ProcessIoFailure))
def test_process_supervisor_reports_typed_io_failures(
    tmp_path: Path,
    failure: ProcessIoFailure,
) -> None:
    stdout = tmp_path / "stdout"
    stderr = tmp_path / "stderr"
    stdin: Path | None = None

    if failure is ProcessIoFailure.OUTPUT_DIRECTORY:
        blocker = tmp_path / "blocker"
        blocker.write_text("not a directory\n")
        stdout = blocker / "stdout"
        expected_error: Exception = ProcessOutputDirectoryCreateError(
            (sys.executable,),
            blocker,
            errno.EEXIST,
        )
        expected_files = (("blocker", b"not a directory\n"),)
    elif failure is ProcessIoFailure.STANDARD_OUTPUT:
        stdout.mkdir()
        expected_error = ProcessStandardOutputOpenError(
            (sys.executable,),
            stdout,
            errno.EISDIR,
        )
        expected_files = (("stdout", None),)
    elif failure is ProcessIoFailure.STANDARD_ERROR:
        stderr.mkdir()
        expected_error = ProcessStandardErrorOpenError(
            (sys.executable,),
            stderr,
            errno.EISDIR,
        )
        expected_files = (("stderr", None), ("stdout", b""))
    else:
        stdin = tmp_path / "missing-input"
        expected_error = ProcessStandardInputOpenError(
            (sys.executable,),
            stdin,
            errno.ENOENT,
        )
        expected_files = (("stderr", b""), ("stdout", b""))

    invocation = ProcessInvocation(
        command=(sys.executable,),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdin=stdin,
        stdout=stdout,
        stderr=stderr,
    )

    with pytest.raises(type(expected_error)) as raised:
        ProcessSupervisor().run(invocation, invocation.command)

    actual_files = tuple(
        (path.name, None if path.is_dir() else path.read_bytes())
        for path in sorted(tmp_path.iterdir())
    )
    assert (raised.value, actual_files) == (expected_error, expected_files)


def read_fifo_records(path: Path, count: int) -> tuple[bytes, ...]:
    """Read complete records from a FIFO without using timing as coordination."""

    descriptor = os.open(path, os.O_RDWR)
    with os.fdopen(descriptor, "rb") as fifo:
        return tuple(fifo.readline() for _ in range(count))


def stoppable_interactive_invocation(
    tmp_path: Path,
) -> tuple[ProcessInvocation, Path, Path]:
    """Create a child that reports both readiness and supervisor shutdown."""

    ready = tmp_path / "ready"
    stopped = tmp_path / "stopped"
    os.mkfifo(ready)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import pathlib, signal, sys\n"
                "def stop(*_):\n"
                "    pathlib.Path(sys.argv[2]).write_text('stopped\\n')\n"
                "    raise SystemExit\n"
                "signal.signal(signal.SIGINT, stop)\n"
                "with open(sys.argv[1], 'w') as ready:\n"
                "    ready.write('ready\\n')\n"
                "signal.pause()\n"
            ),
            str(ready),
            str(stopped),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )
    return invocation, ready, stopped


def synchronize_process_start(
    monkeypatch: pytest.MonkeyPatch,
    ready: Path,
) -> threading.Event:
    """Hold process construction until its signal handler is installed."""

    original_start = process_runtime.subprocess.Popen
    started = threading.Event()

    def start_process(*args, **kwargs):
        process = original_start(*args, **kwargs)
        with ready.open() as ready_stream:
            assert ready_stream.read() == "ready\n"
        started.set()
        return process

    monkeypatch.setattr(process_runtime.subprocess, "Popen", start_process)
    return started


def test_process_supervisor_cancels_an_active_process_group(tmp_path: Path) -> None:
    supervisor = ProcessSupervisor()
    ready = tmp_path / "ready"
    os.mkfifo(ready)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import signal, sys; "
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(130)); "
                "open(sys.argv[1], 'w').write('ready\\n'); "
                "signal.pause()"
            ),
            str(ready),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        result = executor.submit(supervisor.run, invocation, invocation.command)
        with ready.open() as signal_file:
            assert signal_file.read() == "ready\n"
        supervisor.cancel()

        with pytest.raises(RunCancelled):
            result.result()

    assert {
        path.name: path.read_text() for path in tmp_path.iterdir() if path.is_file()
    } == {"stderr": "", "stdout": ""}


def test_kill_ends_a_signal_immune_group_without_escalation(tmp_path: Path) -> None:
    supervisor = ProcessSupervisor()
    ready = tmp_path / "ready"
    os.mkfifo(ready)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import signal, sys; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "open(sys.argv[1], 'w').write('ready\\n'); "
                "signal.pause()"
            ),
            str(ready),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        result = executor.submit(supervisor.run, invocation, invocation.command)
        with ready.open() as signal_file:
            assert signal_file.read() == "ready\n"
        kill_active_process_groups()

        with pytest.raises(RunCancelled):
            result.result()


def test_cancellation_during_an_interactive_callback_is_not_reclassified(
    tmp_path: Path,
) -> None:
    supervisor = ProcessSupervisor()
    started = threading.Event()
    release = threading.Event()
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import json, signal, sys\n"
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n"
                "print(json.dumps({'kind': 'request'}), flush=True)\n"
                "sys.stdin.readline()\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        result = executor.submit(
            supervisor.run_interactive,
            invocation,
            invocation.command,
            BlockingResponseSession(started, release),
        )
        started.wait()
        supervisor.cancel()
        release.set()

        with pytest.raises(RunCancelled):
            result.result()

    assert (
        tuple(
            msgspec.json.decode(line)
            for line in invocation.stdout.read_bytes().splitlines()
        ),
        invocation.stderr.read_text(),
    ) == (({"kind": "request"},), "")


def test_process_supervisor_supplies_secrets_through_an_inherited_descriptor(
    tmp_path: Path,
) -> None:
    supervisor = ProcessSupervisor()
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import os; "
                "descriptor = int(os.environ['TOKEN_FD']); "
                "print(os.read(descriptor, 1024).decode())"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"instance-secret"),),
    )

    result = supervisor.run(invocation, invocation.command)

    assert (
        result,
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
        invocation.environment.get("TOKEN_FD"),
    ) == (ProcessResult(0), "instance-secret\n", "", None)


def test_process_supervisor_completes_short_secret_pipe_writes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original_fdopen = os.fdopen

    def open_short_writer(
        descriptor: int,
        mode: Literal["wb"],
        buffering: int,
    ) -> ShortWriter:
        return ShortWriter(original_fdopen(descriptor, mode, buffering=buffering))

    monkeypatch.setattr(os, "fdopen", open_short_writer)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import os; "
                "descriptor = int(os.environ['TOKEN_FD']); "
                "print(os.fdopen(descriptor, 'rb').read().decode())"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"instance-secret"),),
    )

    result = ProcessSupervisor().run(invocation, invocation.command)

    assert (result, invocation.stdout.read_text(), invocation.stderr.read_text()) == (
        ProcessResult(0),
        "instance-secret\n",
        "",
    )


def test_secret_pipe_open_failure_closes_both_descriptors(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation = ProcessInvocation(
        command=(sys.executable, "-c", "raise SystemExit"),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"secret"),),
    )
    descriptors_before = tuple(sorted(os.listdir("/dev/fd")))

    def reject_file_descriptor(
        descriptor: int,
        mode: str,
        buffering: int,
    ) -> None:
        del descriptor, mode, buffering
        raise OSError(errno.EMFILE, "fixture descriptor failure")

    monkeypatch.setattr(os, "fdopen", reject_file_descriptor)

    with pytest.raises(ProcessSecretPipeOpenError) as raised:
        ProcessSupervisor().run(invocation, invocation.command)

    assert (
        raised.value.command,
        raised.value.environment_variable,
        raised.value.cause.errno,
        tuple(sorted(os.listdir("/dev/fd"))),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        invocation.command,
        "TOKEN_FD",
        errno.EMFILE,
        descriptors_before,
        "",
        "",
    )


def test_process_supervisor_reports_a_secret_rejected_by_an_exited_child(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(sys.executable, "-c", "raise SystemExit"),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"s" * 1_048_576),),
    )

    with pytest.raises(ProcessSecretWriteError) as raised:
        ProcessSupervisor().run(invocation, invocation.command)

    assert (
        raised.value.command,
        raised.value.environment_variable,
        type(raised.value.cause),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (invocation.command, "TOKEN_FD", BrokenPipeError, "", "")


def test_secret_delivery_failure_is_not_reclassified_during_process_cleanup(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import os, signal; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "os.close(int(os.environ['TOKEN_FD'])); "
                "signal.pause()"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"s" * 1_048_576),),
    )

    with pytest.raises(ProcessSecretWriteError) as raised:
        ProcessSupervisor().run(invocation, invocation.command)

    assert (
        raised.value.command,
        raised.value.environment_variable,
        type(raised.value.cause),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (invocation.command, "TOKEN_FD", BrokenPipeError, "", "")


def test_process_supervisor_drives_and_records_an_interactive_session(
    tmp_path: Path,
) -> None:
    supervisor = ProcessSupervisor()
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import json, sys\n"
                "initial = [json.loads(sys.stdin.readline()) for _ in range(2)]\n"
                "print(json.dumps({'kind': 'observed', 'input': initial}), flush=True)\n"
                "print(json.dumps({'kind': 'request', 'id': 'refresh'}), flush=True)\n"
                "response = json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'kind': 'observed-response', 'value': response}), flush=True)\n"
                "print(json.dumps({'kind': 'result'}), flush=True)\n"
                "remaining = sys.stdin.buffer.read().decode()\n"
                "print(json.dumps({'kind': 'closed', 'remaining': remaining}), flush=True)\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    result = supervisor.run_interactive(
        invocation,
        invocation.command,
        ScriptedSession(),
    )

    assert (
        result,
        tuple(
            msgspec.json.decode(line)
            for line in invocation.stdout.read_bytes().splitlines()
        ),
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(0),
        (
            {
                "kind": "observed",
                "input": [{"kind": "initialize"}, {"kind": "task"}],
            },
            {"kind": "request", "id": "refresh"},
            {
                "kind": "observed-response",
                "value": {"kind": "response", "token": "new"},
            },
            {"kind": "result"},
            {"kind": "closed", "remaining": ""},
        ),
        "",
    )


def test_process_supervisor_timestamps_output_before_session_processing(
    tmp_path: Path,
) -> None:
    release = threading.Event()
    session = DelayedSession(release)
    stdout = tmp_path / "stdout"
    os.mkfifo(stdout)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            "print('first', flush=True); print('second', flush=True)",
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=stdout,
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        running = executor.submit(
            ProcessSupervisor().run_interactive,
            invocation,
            invocation.command,
            session,
        )
        transcript = read_fifo_records(stdout, 2)
        released_at = time.monotonic()
        release.set()
        result = running.result()

    first, second = session.records
    assert (
        result,
        tuple(record.value for record in session.records),
        first.received_at <= second.received_at <= released_at,
        transcript,
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(0),
        (b"first\n", b"second\n"),
        True,
        (b"first\n", b"second\n"),
        "",
    )


def test_process_supervisor_rejects_static_interactive_input(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(sys.executable, "-c", "raise SystemExit"),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        stdin=Path("static-input"),
    )

    with pytest.raises(ProcessInteractiveInputConflictError) as raised:
        ProcessSupervisor().run_interactive(
            invocation,
            invocation.command,
            ScriptedSession(),
        )

    assert raised.value == ProcessInteractiveInputConflictError(Path("static-input"))


def test_wakeup_creation_failure_stops_the_started_process(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation, ready, stopped = stoppable_interactive_invocation(tmp_path)
    started = synchronize_process_start(monkeypatch, ready)
    original_pipe = process_runtime.os.pipe

    def create_pipe() -> tuple[int, int]:
        if started.is_set():
            raise OSError(errno.EMFILE, "fixture descriptor exhaustion")
        return original_pipe()

    monkeypatch.setattr(process_runtime.os, "pipe", create_pipe)

    with pytest.raises(ProcessOutputWakeupCreateError) as raised:
        ProcessSupervisor().run_interactive(
            invocation,
            invocation.command,
            SilentSession(),
        )

    assert (
        raised.value.command,
        raised.value.cause.errno,
        stopped.read_text(),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        invocation.command,
        errno.EMFILE,
        "stopped\n",
        "",
        "",
    )


def test_output_channel_allocation_failure_stops_the_started_process(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation, ready, stopped = stoppable_interactive_invocation(tmp_path)
    synchronize_process_start(monkeypatch, ready)

    def reject_output_channel(*_args: object) -> None:
        raise MemoryError

    monkeypatch.setattr(process_runtime, "_OutputChannel", reject_output_channel)

    with pytest.raises(ProcessOutputBufferError) as raised:
        ProcessSupervisor().run_interactive(
            invocation,
            invocation.command,
            SilentSession(),
        )

    assert (
        raised.value,
        stopped.read_text(),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessOutputBufferError(invocation.command),
        "stopped\n",
        "",
        "",
    )


def test_process_supervisor_reaps_a_child_after_a_session_failure(
    tmp_path: Path,
) -> None:
    supervisor = ProcessSupervisor()
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import json, os, signal, sys\n"
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n"
                "print(json.dumps({'pid': os.getpid()}), flush=True)\n"
                "signal.pause()\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with pytest.raises(ClaudeControlRequestUnsupportedError) as raised:
        supervisor.run_interactive(invocation, invocation.command, FailingSession())

    transcript = tuple(
        msgspec.json.decode(line)
        for line in invocation.stdout.read_bytes().splitlines()
    )
    (event,) = transcript
    with pytest.raises(ProcessLookupError):
        os.kill(event["pid"], 0)
    supervisor.cancel()

    assert (raised.value, transcript, invocation.stderr.read_text()) == (
        ClaudeControlRequestUnsupportedError("fixture_failure"),
        ({"pid": event["pid"]},),
        "",
    )


def test_session_failure_releases_an_output_reader_waiting_on_backpressure(
    tmp_path: Path,
) -> None:
    release = threading.Event()
    stdout = tmp_path / "stdout"
    os.mkfifo(stdout)
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import json, signal, sys\n"
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n"
                "for value in range(100):\n"
                "    print(json.dumps({'value': value}), flush=True)\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=stdout,
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        running = executor.submit(
            ProcessSupervisor().run_interactive,
            invocation,
            invocation.command,
            BackloggedFailingSession(release),
        )
        transcript = read_fifo_records(stdout, 3)
        release.set()
        with pytest.raises(ClaudeControlRequestUnsupportedError) as raised:
            running.result()

    assert (
        raised.value,
        tuple(
            thread.name
            for thread in threading.enumerate()
            if thread.name.startswith("process-output-")
        ),
        tuple(msgspec.json.decode(record) for record in transcript),
        invocation.stderr.read_text(),
    ) == (
        ClaudeControlRequestUnsupportedError("fixture_failure"),
        (),
        ({"value": 0}, {"value": 1}, {"value": 2}),
        "",
    )


def test_process_supervisor_rejects_an_oversized_output_record(
    tmp_path: Path,
) -> None:
    maximum_bytes = 16 * 1024 * 1024
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                # The supervisor's stop escalation reaches this child while it
                # is still writing, and Python's own SIGINT handling would
                # print a traceback the assertion below would then attribute
                # to the supervisor.
                "import signal, sys\n"
                "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                f"sys.stdout.write('x' * {maximum_bytes + 1})\n"
                "sys.stdout.flush()\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with pytest.raises(ProcessOutputRecordLimitError) as raised:
        ProcessSupervisor().run_interactive(
            invocation,
            invocation.command,
            SilentSession(),
        )

    assert (
        raised.value,
        invocation.stdout.read_bytes(),
        invocation.stderr.read_text(),
    ) == (
        ProcessOutputRecordLimitError(invocation.command, maximum_bytes),
        b"",
        "",
    )


def test_process_supervisor_closes_input_when_interactive_output_ends(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import os, sys\n"
                "os.close(sys.stdout.fileno())\n"
                "raise SystemExit(0 if sys.stdin.buffer.read() == b'' else 1)\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        SilentSession(),
    )

    assert (result, invocation.stdout.read_text(), invocation.stderr.read_text()) == (
        ProcessResult(0),
        "",
        "",
    )


def test_process_supervisor_retains_output_written_immediately_before_exit(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(sys.executable, "-c", "print('final record', flush=True)"),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        SilentSession(),
    )

    assert (result, invocation.stdout.read_text(), invocation.stderr.read_text()) == (
        ProcessResult(return_code=0),
        "final record\n",
        "",
    )


def test_process_supervisor_retains_a_complete_finite_burst_before_exit(
    tmp_path: Path,
) -> None:
    session = RecordingSession()
    expected = tuple(f"record {value}\n".encode() for value in range(1_000))
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            "for value in range(1000): print(f'record {value}', flush=True)",
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        session,
    )

    assert (
        result,
        tuple(record.value for record in session.records),
        tuple(invocation.stdout.read_bytes().splitlines(keepends=True)),
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(return_code=0),
        expected,
        expected,
        "",
    )


def test_process_supervisor_handles_output_on_a_high_numbered_descriptor(
    tmp_path: Path,
) -> None:
    descriptors: list[int] = []
    maximum_descriptor = -1
    soft_limit, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(
            resource.RLIMIT_NOFILE,
            (max(soft_limit, 1_200), hard_limit),
        )
        while maximum_descriptor < 1_100:
            maximum_descriptor = os.open(os.devnull, os.O_RDONLY)
            descriptors.append(maximum_descriptor)

        session = RecordingSession()
        invocation = ProcessInvocation(
            command=(sys.executable, "-c", "print('record', flush=True)"),
            cwd=tmp_path,
            environment=dict(os.environ),
            capabilities=ProcessCapabilities((), NetworkAccess.NONE),
            stdout=tmp_path / "stdout",
            stderr=tmp_path / "stderr",
        )

        result = ProcessSupervisor().run_interactive(
            invocation,
            invocation.command,
            session,
        )
        outcome = (
            result,
            tuple(record.value for record in session.records),
            tuple(invocation.stdout.read_bytes().splitlines(keepends=True)),
            invocation.stderr.read_text(),
        )
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft_limit, hard_limit))

    assert outcome == (
        ProcessResult(return_code=0),
        (b"record\n",),
        (b"record\n",),
        "",
    )


def test_process_supervisor_stops_descendants_after_the_leader_exits(
    tmp_path: Path,
) -> None:
    descendant_ready = tmp_path / "descendant-ready"
    descendant_stopped = tmp_path / "descendant-stopped"
    os.mkfifo(descendant_ready)
    descendant = (
        "import pathlib, signal, sys\n"
        "def stop(*_):\n"
        "    pathlib.Path(sys.argv[2]).write_text('stopped\\n')\n"
        "    raise SystemExit\n"
        "signal.signal(signal.SIGINT, stop)\n"
        "with open(sys.argv[1], 'w') as ready:\n"
        "    ready.write('ready\\n')\n"
        "signal.pause()\n"
    )
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import subprocess, sys\n"
                f"subprocess.Popen([sys.executable, '-c', {descendant!r}, sys.argv[1], sys.argv[2]])\n"
                "with open(sys.argv[1]) as ready:\n"
                "    ready.read()\n"
            ),
            str(descendant_ready),
            str(descendant_stopped),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        SilentSession(),
    )

    assert (
        result,
        invocation.stdout.read_text(),
        descendant_stopped.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(return_code=0),
        "",
        "stopped\n",
        "",
    )


@SUPERVISOR_STARTS
def test_process_supervisor_stops_a_child_that_outlives_its_deadline(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    start: Start,
) -> None:
    invocation, ready, stopped = stoppable_interactive_invocation(tmp_path)
    invocation = replace(invocation, deadline_seconds=0.05)
    synchronize_process_start(monkeypatch, ready)

    with pytest.raises(ProcessDeadlineExceededError) as raised:
        start(ProcessSupervisor(), invocation)

    assert (
        raised.value,
        stopped.read_text(),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessDeadlineExceededError(invocation.command, 0.05),
        "stopped\n",
        "",
        "",
    )


@SUPERVISOR_STARTS
def test_process_supervisor_leaves_a_child_within_its_deadline_alone(
    tmp_path: Path,
    start: Start,
) -> None:
    invocation = ProcessInvocation(
        command=(sys.executable, "-c", "print('finished', flush=True)"),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        deadline_seconds=20.0,
    )

    result = start(ProcessSupervisor(), invocation)

    assert (result, invocation.stdout.read_text(), invocation.stderr.read_text()) == (
        ProcessResult(return_code=0),
        "finished\n",
        "",
    )


def test_process_supervisor_tears_concurrent_process_groups_down_together(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(process_runtime, "_STOP_SIGNAL_SECONDS", 0.2)
    signals: list[tuple[int, int]] = []
    recording = threading.Lock()
    original_signal_group = process_runtime.ProcessSupervisor._signal_group

    def record_signal(
        managed: process_runtime._ManagedProcess,
        signal_number: int,
    ) -> None:
        with recording:
            signals.append((managed.group, signal_number))
        original_signal_group(managed, signal_number)

    monkeypatch.setattr(
        process_runtime.ProcessSupervisor,
        "_signal_group",
        staticmethod(record_signal),
    )

    def invocation(name: str) -> ProcessInvocation:
        return ProcessInvocation(
            command=(
                sys.executable,
                "-c",
                (
                    "import os, signal\n"
                    "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    "print(os.getpid(), flush=True)\n"
                    "signal.pause()\n"
                ),
            ),
            cwd=tmp_path,
            environment=dict(os.environ),
            capabilities=ProcessCapabilities((), NetworkAccess.NONE),
            stdout=tmp_path / f"{name}-stdout",
            stderr=tmp_path / f"{name}-stderr",
        )

    supervisor = ProcessSupervisor()
    session = SynchronizedFailingSession(threading.Barrier(2))
    invocations = (invocation("first"), invocation("second"))

    outcomes: list[Exception] = []
    with ThreadPoolExecutor(max_workers=2) as executor:
        running = tuple(
            executor.submit(
                supervisor.run_interactive,
                value,
                value.command,
                session,
            )
            for value in invocations
        )
        for task in running:
            with pytest.raises(ClaudeControlRequestUnsupportedError) as raised:
                task.result()
            outcomes.append(raised.value)

    opening = tuple(number for _, number in signals[:2])
    assert (
        opening,
        len({process_id for process_id, _ in signals[:2]}),
        tuple(outcomes),
    ) == (
        (signal.SIGINT, signal.SIGINT),
        2,
        (ClaudeControlRequestUnsupportedError("fixture_failure"),) * 2,
    )


def test_process_supervisor_bounds_secret_delivery_by_the_deadline(
    tmp_path: Path,
) -> None:
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import signal, sys\n"
                "signal.signal(signal.SIGINT, lambda *_: sys.exit(130))\n"
                "signal.pause()\n"
            ),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
        secrets=(SecretFileDescriptor("TOKEN_FD", b"s" * 1_048_576),),
        deadline_seconds=0.05,
    )

    with pytest.raises(ProcessDeadlineExceededError) as raised:
        ProcessSupervisor().run(invocation, invocation.command)

    # The deadline is short enough that the child can still be starting up when
    # the stop escalation interrupts it, and an interpreter which has not yet
    # reached its own signal handler reports that on standard error itself.
    assert (raised.value, invocation.stdout.read_text()) == (
        ProcessDeadlineExceededError(invocation.command, 0.05),
        "",
    )


def test_output_channel_prioritizes_leader_completion_over_queued_output() -> None:
    deadline = process_runtime._ProcessDeadline.start(("fixture",), 30.0)
    wakeup_read, wakeup_write = os.pipe()
    try:
        channel = process_runtime._OutputChannel(("fixture",), wakeup_write)
        record = ProcessOutputRecord(b"queued\n", 0)
        sent = channel.send(record)
        channel.finish_leader()

        first = channel.receive(deadline)
        second = channel.receive(deadline)
        channel.finish(None)
        third = channel.receive(deadline)
    finally:
        os.close(wakeup_read)
        os.close(wakeup_write)

    assert (sent, first, second, third) == (
        True,
        process_runtime._OutputEvent.LEADER_FINISHED,
        record,
        None,
    )


def test_leader_completion_stops_continuing_descendant_output(
    tmp_path: Path,
) -> None:
    descendant_ready = tmp_path / "descendant-ready"
    descendant_stopped = tmp_path / "descendant-stopped"
    os.mkfifo(descendant_ready)
    descendant = (
        "import itertools, pathlib, signal, sys\n"
        "def stop(*_):\n"
        "    pathlib.Path(sys.argv[2]).write_text('stopped\\n')\n"
        "    raise SystemExit\n"
        "signal.signal(signal.SIGINT, stop)\n"
        "print(0, flush=True)\n"
        "with open(sys.argv[1], 'w') as ready:\n"
        "    ready.write('ready\\n')\n"
        "for value in itertools.count(1):\n"
        "    print(value, flush=True)\n"
    )
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import subprocess, sys\n"
                f"subprocess.Popen([sys.executable, '-c', {descendant!r}, sys.argv[1], sys.argv[2]])\n"
                "with open(sys.argv[1]) as ready:\n"
                "    ready.read()\n"
            ),
            str(descendant_ready),
            str(descendant_stopped),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    session = RecordingSession()
    result = ProcessSupervisor().run_interactive(
        invocation,
        invocation.command,
        session,
    )

    session_values = tuple(int(record.value) for record in session.records)
    transcript_values = tuple(
        int(record) for record in invocation.stdout.read_bytes().splitlines()
    )
    expected = tuple(range(len(session_values)))
    assert (
        result,
        session_values,
        transcript_values,
        min(session_values, default=None),
        descendant_stopped.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(return_code=0),
        expected,
        expected,
        0,
        "stopped\n",
        "",
    )


def test_leader_completion_stops_waiting_for_an_escaped_output_owner(
    tmp_path: Path,
) -> None:
    descendant_pid = tmp_path / "descendant-pid"
    leader_ready = tmp_path / "leader-ready"
    os.mkfifo(leader_ready)
    descendant = "import signal\nsignal.pause()\n"
    invocation = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import pathlib, subprocess, sys\n"
                "child = subprocess.Popen(\n"
                f"    [sys.executable, '-c', {descendant!r}],\n"
                "    start_new_session=True,\n"
                ")\n"
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid))\n"
                "with open(sys.argv[2], 'w') as ready:\n"
                "    ready.write('ready\\n')\n"
            ),
            str(descendant_pid),
            str(leader_ready),
        ),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with ThreadPoolExecutor(max_workers=1) as executor:
        running = executor.submit(
            ProcessSupervisor().run_interactive,
            invocation,
            invocation.command,
            SilentSession(),
        )
        with leader_ready.open() as signal_file:
            assert signal_file.read() == "ready\n"
        try:
            result = running.result()
        finally:
            pid = int(descendant_pid.read_text())
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    assert (
        result,
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessResult(return_code=0),
        "",
        "",
    )


# A sandbox which starts its own session, as bubblewrap's --new-session does,
# reports the session leader it created; only that group holds the command.
SANDBOX_LEADER = (
    "import os, pathlib, signal, sys\n"
    "descriptor = int(sys.argv[1])\n"
    "stopped = pathlib.Path(sys.argv[2])\n"
    "leader = os.fork()\n"
    "if leader == 0:\n"
    "    os.setsid()\n"
    "    def stop(*_):\n"
    "        stopped.write_text('stopped\\n')\n"
    "        raise SystemExit\n"
    "    signal.signal(signal.SIGINT, stop)\n"
    "    os.write(descriptor, b'{\"child-pid\": %d}' % os.getpid())\n"
    "    os.close(descriptor)\n"
    "    signal.pause()\n"
    "os.close(descriptor)\n"
    "os.waitpid(leader, 0)\n"
)

SANDBOX_WITHOUT_A_REPORT = (
    "import os, signal, sys\n"
    "signal.signal(signal.SIGINT, lambda *_: sys.exit(130))\n"
    "os.close(int(sys.argv[1]))\n"
    "signal.pause()\n"
)


def test_process_supervisor_stops_the_process_group_a_sandbox_reports(
    tmp_path: Path,
) -> None:
    stopped = tmp_path / "stopped"
    with process_runtime.SandboxInfoPipe.open(("sandbox",)) as sandbox:
        invocation = ProcessInvocation(
            command=(
                sys.executable,
                "-c",
                SANDBOX_LEADER,
                str(sandbox.write_descriptor),
                str(stopped),
            ),
            cwd=tmp_path,
            environment=dict(os.environ),
            capabilities=ProcessCapabilities((), NetworkAccess.NONE),
            stdout=tmp_path / "stdout",
            stderr=tmp_path / "stderr",
            deadline_seconds=1.0,
        )

        with pytest.raises(ProcessDeadlineExceededError) as raised:
            ProcessSupervisor().run(invocation, invocation.command, sandbox)

    assert (
        raised.value,
        stopped.read_text(),
        invocation.stdout.read_text(),
        invocation.stderr.read_text(),
    ) == (
        ProcessDeadlineExceededError(invocation.command, 1.0),
        "stopped\n",
        "",
        "",
    )


def test_process_supervisor_stops_the_outer_group_without_a_sandbox_report(
    tmp_path: Path,
) -> None:
    with process_runtime.SandboxInfoPipe.open(("sandbox",)) as sandbox:
        invocation = ProcessInvocation(
            command=(
                sys.executable,
                "-c",
                SANDBOX_WITHOUT_A_REPORT,
                str(sandbox.write_descriptor),
            ),
            cwd=tmp_path,
            environment=dict(os.environ),
            capabilities=ProcessCapabilities((), NetworkAccess.NONE),
            stdout=tmp_path / "stdout",
            stderr=tmp_path / "stderr",
            deadline_seconds=1.0,
        )

        with pytest.raises(ProcessDeadlineExceededError) as raised:
            ProcessSupervisor().run(invocation, invocation.command, sandbox)

    assert (raised.value, invocation.stdout.read_text()) == (
        ProcessDeadlineExceededError(invocation.command, 1.0),
        "",
    )


def test_managed_process_targets_the_group_a_sandbox_reports() -> None:
    process = subprocess.Popen((sys.executable, "-c", "pass"))
    try:
        outer = process_runtime._ManagedProcess(process, ("sandbox",))
        inner = process_runtime._ManagedProcess(process, ("sandbox",), 4_321)
    finally:
        process.wait()

    assert (outer.group, inner.group) == (process.pid, 4_321)


@pytest.mark.parametrize(
    ("document", "expected"),
    (
        (b'{"child-pid": 1234}', 1234),
        (b'{\n    "child-pid": 1234,\n    "cgroup-namespace": 7\n}\n', 1234),
        (b"", None),
    ),
    ids=("compact", "complete", "unreported"),
)
def test_sandbox_info_pipe_reads_the_reported_group(
    document: bytes,
    expected: int | None,
) -> None:
    deadline = process_runtime._ProcessDeadline.start(("sandbox",), 30.0)
    with process_runtime.SandboxInfoPipe.open(("sandbox",)) as sandbox:
        os.write(sandbox.write_descriptor, document)
        sandbox.close_write()

        group = sandbox.read_group(("sandbox",), deadline)

    assert (group, sandbox.read_descriptor, sandbox.write_descriptor) == (
        expected,
        -1,
        -1,
    )


def test_sandbox_info_pipe_rejects_an_unusable_document() -> None:
    deadline = process_runtime._ProcessDeadline.start(("sandbox",), 30.0)
    document = b'{"child-pid": "one"}'
    with process_runtime.SandboxInfoPipe.open(("sandbox",)) as sandbox:
        os.write(sandbox.write_descriptor, document)
        sandbox.close_write()

        with pytest.raises(ProcessSandboxInfoInvalidError) as raised:
            sandbox.read_group(("sandbox",), deadline)

    assert raised.value == ProcessSandboxInfoInvalidError(("sandbox",), document)


def test_sandbox_info_pipe_closes_after_a_failed_start(tmp_path: Path) -> None:
    invocation = ProcessInvocation(
        command=(str(tmp_path / "missing"),),
        cwd=tmp_path,
        environment=dict(os.environ),
        capabilities=ProcessCapabilities((), NetworkAccess.NONE),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )

    with (
        process_runtime.SandboxInfoPipe.open(invocation.command) as sandbox,
        pytest.raises(ProcessStartError) as raised,
    ):
        ProcessSupervisor().run(invocation, invocation.command, sandbox)

    assert (
        raised.value,
        sandbox.read_descriptor,
        sandbox.write_descriptor,
    ) == (
        ProcessStartError(invocation.command, errno.ENOENT, str(tmp_path / "missing")),
        -1,
        -1,
    )
