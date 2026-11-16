import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path

launcher, fixture = sys.argv[1:]
terminal, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 120, 0, 0))
child = subprocess.Popen(
    [launcher, "--offline", "--provider", "fixture", "--model", "gpt-test", "-e", fixture],
    env={**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor"},
    stdin=slave,
    stdout=slave,
    stderr=slave,
    start_new_session=True,
)
# Keep the slave descriptor open until Pi has been read to the end. macOS
# discards unread PTY output when the last slave descriptor closes.
output = bytearray()
# Pi can take minutes to start on a loaded builder, so the timeout only
# catches a run that has hung.
hang_timeout = 600


def drain():
    if not select.select([terminal], [], [], 0.05)[0]:
        return False
    try:
        data = os.read(terminal, 65536)
    except OSError:
        return False
    output.extend(data)
    if b"\x1b[6n" in data:
        os.write(terminal, b"\x1b[1;1R")
    if b"\x1b]11;?" in data:
        os.write(terminal, b"\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\")
    return bool(data)


def wait_for(predicate, description):
    deadline = time.monotonic() + hang_timeout
    while True:
        exited = child.poll() is not None
        if exited:
            while drain():
                pass
        else:
            drain()
        if predicate():
            return
        if exited:
            raise AssertionError(
                f"Pi exited with status {child.returncode} "
                f"while waiting for {description}\n"
                + output.decode(errors="replace")[-8000:]
            )
        if time.monotonic() >= deadline:
            raise AssertionError(
                f"Timed out after {hang_timeout} s waiting for {description}\n"
                + output.decode(errors="replace")[-8000:]
            )


try:
    wait_for(
        lambda: b"profile-fixture-ready" in output,
        "the ready marker in Pi's editor",
    )
    os.write(terminal, b"\x15/dotfiles-profile-lifecycle\r")
    wait_for(
        lambda: Path("lifecycle-probe-ok").is_file(),
        "the lifecycle probe result",
    )
    assert not Path("unexpected-model-turn").exists()
    os.write(terminal, b"\x15\x04")
    wait_for(lambda: child.poll() is not None, "Pi to exit")
    assert child.returncode == 0, output.decode(errors="replace")[-8000:]
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
    os.close(slave)
    os.close(terminal)
