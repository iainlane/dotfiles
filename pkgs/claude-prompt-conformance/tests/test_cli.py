from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import overload

import pytest

from claude_prompt_conformance.cli import (
    ImprovementCalibrationConflictError,
    InterruptEscalation,
    main,
    setup_error,
    validate_run_mode,
)


class InterruptingArguments(Sequence[str]):
    @overload
    def __getitem__(self, index: int) -> str: ...
    @overload
    def __getitem__(self, index: slice) -> Sequence[str]: ...
    def __getitem__(self, index: int | slice) -> str | Sequence[str]:
        raise KeyboardInterrupt

    def __len__(self) -> int:
        return 1


def test_cli_returns_the_conventional_status_for_sigint() -> None:
    assert main(InterruptingArguments()) == 130


@dataclass
class AnnouncementRecorder:
    messages: list[str] = field(default_factory=list)

    def announce(self, message: str) -> None:
        self.messages.append(message)


@dataclass
class ForcedExit(Exception):
    status: int


def test_a_second_interrupt_kills_agents_and_exits_immediately() -> None:
    frontend = AnnouncementRecorder()
    killed: list[bool] = []

    def exit_now(status: int) -> None:
        raise ForcedExit(status)

    handler = InterruptEscalation(
        frontend,
        kill=lambda: killed.append(True),
        exit_now=exit_now,
    )

    with pytest.raises(KeyboardInterrupt):
        handler(2, None)
    with pytest.raises(ForcedExit) as forced:
        handler(2, None)

    banner = (
        "Interrupt received: stopping agents. Press Ctrl-C again to exit immediately."
    )
    assert (frontend.messages, killed, forced.value) == (
        [banner],
        [True],
        ForcedExit(130),
    )


def test_prompt_improvement_requires_calibrated_evidence() -> None:
    with pytest.raises(ImprovementCalibrationConflictError) as raised:
        validate_run_mode(improve=True, skip_calibration=True)

    assert raised.value == ImprovementCalibrationConflictError()


def test_json_setup_failure_has_a_structural_error(tmp_path, capsys) -> None:
    error = ImprovementCalibrationConflictError()

    assert setup_error(error, "json") == 2
    assert capsys.readouterr().out == (
        '{"event": "SetupFailed", "error": '
        '{"type": "ImprovementCalibrationConflictError", '
        '"description": "--skip-calibration cannot be used during prompt improvement"}}\n'
    )
