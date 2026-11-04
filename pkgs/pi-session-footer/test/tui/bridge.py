import base64
import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios


def emit(message):
    print(json.dumps(message), flush=True)


def resize(fd, columns, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def main():
    config = json.loads(sys.stdin.buffer.readline())
    master, slave = pty.openpty()
    resize(slave, config["columns"], config["rows"])
    child = subprocess.Popen(
        config["command"],
        cwd=config["cwd"],
        env=config["env"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    pending = b""

    try:
        while child.poll() is None:
            readable, _, _ = select.select([master, sys.stdin], [], [], 0.1)

            if master in readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break

                if not data:
                    break

                emit({"type": "data", "data": base64.b64encode(data).decode("ascii")})

            if sys.stdin not in readable:
                continue

            data = os.read(sys.stdin.fileno(), 65536)

            if not data:
                break

            pending += data

            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                command = json.loads(line)

                if command["type"] == "resize":
                    resize(master, command["columns"], command["rows"])
                    os.kill(child.pid, signal.SIGWINCH)
                elif command["type"] == "input":
                    os.write(master, base64.b64decode(command["data"]))
                elif command["type"] == "stop":
                    os.killpg(child.pid, signal.SIGTERM)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)

        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)

        os.close(master)
        emit({"type": "exit", "code": child.returncode})


if __name__ == "__main__":
    main()
