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
    def __init__(self, returncode: int = 0, stderr: bytes = b"") -> None:
        self.commands: list[tuple[str, ...]] = []
        self._returncode = returncode
        self._stderr = stderr

    def __call__(
        self,
        command: tuple[str, ...],
    ) -> subprocess.CompletedProcess[bytes]:
        self.commands.append(command)
        link = Path(command[2])
        if self._returncode == 0:
            link.symlink_to(command[4])
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


def test_pinned_closure_roots_a_store_configuration_and_releases_it(
    tmp_path: Path,
) -> None:
    store = tmp_path / "store"
    configuration = store / "abc-configuration.json"
    directory = tmp_path / "runtime"
    runner = RecordingRunner()

    with pinned_closure(
        configuration,
        "nix-store",
        directory,
        "run-7",
        runner=runner,
        store=store,
    ) as link:
        held = link is not None and link.is_symlink()

    assert (runner.commands, held, (directory / "run-7").exists()) == (
        [
            (
                "nix-store",
                "--add-root",
                str(directory / "run-7"),
                "-r",
                str(configuration),
            )
        ],
        True,
        False,
    )


def test_pinned_closure_skips_a_configuration_outside_the_store(
    tmp_path: Path,
) -> None:
    runner = RecordingRunner()

    with pinned_closure(
        tmp_path / "configuration.json",
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
            store / "abc-configuration.json",
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
            store / "abc-configuration.json",
            "nix-store",
            directory,
            "run-7",
            runner=missing,
            store=store,
        ),
    ):
        pass
