import os
import subprocess
from pathlib import Path

import pytest

from claude_prompt_conformance.closure_root import (
    ClosureRootCreateError,
    nix_store_program,
    pinned_closure,
    runtime_directory,
)


class RecordingRunner:
    """Create the links `nix-store --add-root` would create for each store path."""

    def __init__(self, returncode: int = 0, stderr: bytes = b"") -> None:
        self.commands: list[tuple[str, ...]] = []
        self._returncode = returncode
        self._stderr = stderr

    def __call__(
        self,
        command: tuple[str, ...],
    ) -> subprocess.CompletedProcess[bytes]:
        self.commands.append(command)
        base = Path(command[2])
        if self._returncode == 0:
            for position, target in enumerate(command[4:], start=1):
                link = (
                    base if position == 1 else base.with_name(f"{base.name}-{position}")
                )
                link.symlink_to(target)
        return subprocess.CompletedProcess(command, self._returncode, b"", self._stderr)


def test_runtime_directory_prefers_the_session_runtime(tmp_path: Path) -> None:
    assert (
        runtime_directory({"XDG_RUNTIME_DIR": str(tmp_path)}),
        runtime_directory({}).name,
    ) == (tmp_path / "claude-prompt-conformance", "claude-prompt-conformance")


def test_nix_store_program_is_the_configured_nix_sibling() -> None:
    assert nix_store_program("/nix/store/abc-nix/bin/nix") == (
        "/nix/store/abc-nix/bin/nix-store"
    )


def test_pinned_closure_roots_every_store_path_and_releases_each_link(
    tmp_path: Path,
) -> None:
    store = tmp_path / "store"
    directory = tmp_path / "runtime"
    runner = RecordingRunner()
    paths = (
        store / "abc-claude",
        tmp_path / "assembled-by-a-test.json",
        store / "def-codex",
        store / "abc-claude",
    )

    with pinned_closure(
        paths,
        "nix-store",
        directory,
        "run-7",
        runner=runner,
        store=store,
    ) as link:
        held = tuple(sorted(path.name for path in directory.iterdir()))

    assert (runner.commands, link, held, tuple(directory.iterdir())) == (
        [
            (
                "nix-store",
                "--add-root",
                str(directory / "run-7"),
                "-r",
                str(store / "abc-claude"),
                str(store / "def-codex"),
            )
        ],
        directory / "run-7",
        ("run-7", "run-7-2"),
        (),
    )


def test_pinned_closure_sweeps_the_links_of_runs_which_have_gone(
    tmp_path: Path,
) -> None:
    store = tmp_path / "store"
    directory = tmp_path / "runtime"
    directory.mkdir()
    for name in ("run-2147483647", "run-2147483647-2"):
        (directory / name).symlink_to(store / "old-claude")
    unrelated = directory / "note.txt"
    unrelated.write_text("kept\n")

    with pinned_closure(
        (store / "abc-claude",),
        "nix-store",
        directory,
        f"run-{os.getpid()}",
        runner=RecordingRunner(),
        store=store,
    ):
        remaining = tuple(sorted(path.name for path in directory.iterdir()))

    assert remaining == ("note.txt", f"run-{os.getpid()}")


def test_pinned_closure_skips_a_configuration_outside_the_store(
    tmp_path: Path,
) -> None:
    runner = RecordingRunner()

    with pinned_closure(
        (tmp_path / "claude", tmp_path / "codex"),
        "nix-store",
        tmp_path / "runtime",
        "run-7",
        runner=runner,
        store=tmp_path / "store",
    ) as link:
        pass

    assert (runner.commands, link) == ([], None)


def test_pinned_closure_reports_a_failed_root_creation(tmp_path: Path) -> None:
    store = tmp_path / "store"
    directory = tmp_path / "runtime"

    with (
        pytest.raises(ClosureRootCreateError) as raised,
        pinned_closure(
            (store / "abc-claude",),
            "nix-store",
            directory,
            "run-7",
            runner=RecordingRunner(returncode=1, stderr=b"permission denied\n"),
            store=store,
        ),
    ):
        pass

    assert raised.value == ClosureRootCreateError(
        directory / "run-7",
        "permission denied",
    )


def test_pinned_closure_reports_an_unrunnable_nix_store(tmp_path: Path) -> None:
    store = tmp_path / "store"
    directory = tmp_path / "runtime"

    def missing(command: tuple[str, ...]) -> subprocess.CompletedProcess[bytes]:
        raise FileNotFoundError(2, "No such file or directory", command[0])

    with (
        pytest.raises(ClosureRootCreateError),
        pinned_closure(
            (store / "abc-claude",),
            "nix-store",
            directory,
            "run-7",
            runner=missing,
            store=store,
        ),
    ):
        pass
