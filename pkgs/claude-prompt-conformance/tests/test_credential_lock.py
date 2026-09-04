import os
import time
from dataclasses import dataclass
from pathlib import Path

import pytest

from claude_prompt_conformance.credential_lock import (
    ClaudeCredentialRefreshLock,
    ClaudeCredentialStorageLock,
    CredentialLockCompromisedError,
    CredentialLockTimeoutError,
)


@dataclass
class Clock:
    current: float = 0

    def monotonic(self) -> float:
        return self.current

    def sleep(self, seconds: float) -> None:
        self.current += seconds


def test_claude_credential_lock_uses_the_pinned_clients_lock_paths(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    lock = ClaudeCredentialRefreshLock(configuration)

    with lock:
        held = (
            tuple(path.name for path in configuration.iterdir()),
            Path(f"{configuration.resolve()}.lock").is_dir(),
        )

    assert (
        held,
        tuple(path.name for path in configuration.iterdir()),
        Path(f"{configuration.resolve()}.lock").exists(),
    ) == (
        ((".oauth_refresh.lock",), True),
        (),
        False,
    )


def test_claude_credential_lock_reports_contention_without_stealing_the_lock(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    configuration.mkdir()
    occupied = configuration / ".oauth_refresh.lock"
    occupied.mkdir()
    clock = Clock()
    lock = ClaudeCredentialRefreshLock(
        configuration,
        retry_seconds=lambda _: 0.1,
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    with pytest.raises(CredentialLockTimeoutError) as raised, lock:
        pytest.fail("a contended lock must not be entered")

    assert (
        raised.value,
        occupied.is_dir(),
        tuple(path.name for path in configuration.iterdir()),
        clock,
    ) == (
        CredentialLockTimeoutError(occupied, 0.5),
        True,
        (".oauth_refresh.lock",),
        Clock(0.5),
    )


def test_claude_credential_lock_reclaims_a_stale_client_lock(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    configuration.mkdir()
    stale = configuration / ".oauth_refresh.lock"
    stale.mkdir()
    stale_timestamp = 100.0
    os.utime(stale, (stale_timestamp, stale_timestamp))
    lock = ClaudeCredentialRefreshLock(
        configuration,
        wall_clock=lambda: stale_timestamp + 61,
    )

    with lock:
        held = tuple(path.name for path in configuration.iterdir())

    assert (
        held,
        tuple(path.name for path in configuration.iterdir()),
        Path(f"{configuration.resolve()}.lock").exists(),
    ) == (
        (".oauth_refresh.lock",),
        (),
        False,
    )


def test_claude_credential_lock_treats_an_unusable_legacy_path_as_optional(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    configuration.mkdir()
    legacy = Path(f"{configuration.resolve()}.lock")
    legacy.write_text("not a lock directory")
    stale_timestamp = 100.0
    os.utime(legacy, (stale_timestamp, stale_timestamp))
    lock = ClaudeCredentialRefreshLock(
        configuration,
        wall_clock=lambda: stale_timestamp + 61,
    )

    with lock:
        held = tuple(path.name for path in configuration.iterdir())

    assert (
        held,
        tuple(path.name for path in configuration.iterdir()),
        legacy.read_text(),
    ) == (
        (".oauth_refresh.lock",),
        (),
        "not a lock directory",
    )


def test_claude_credential_storage_lock_has_bounded_contention(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    configuration.mkdir()
    occupied = configuration / ".storage-write.lock"
    occupied.mkdir()
    clock = Clock()
    lock = ClaudeCredentialStorageLock(
        configuration,
        acquisition_attempts=2,
        retry_seconds=lambda _: 0.1,
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    with pytest.raises(CredentialLockTimeoutError) as raised, lock:
        pytest.fail("a contended storage lock must not be entered")

    assert (
        raised.value,
        occupied.is_dir(),
        tuple(path.name for path in configuration.iterdir()),
        clock,
    ) == (
        CredentialLockTimeoutError(occupied, 0.1),
        True,
        (".storage-write.lock",),
        Clock(0.1),
    )


def test_claude_credential_storage_lock_uses_the_pinned_retry_schedule(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    configuration.mkdir()
    occupied = configuration / ".storage-write.lock"
    occupied.mkdir()
    clock = Clock()
    lock = ClaudeCredentialStorageLock(
        configuration,
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    with pytest.raises(CredentialLockTimeoutError) as raised, lock:
        pytest.fail("a contended storage lock must not be entered")

    assert (raised.value, occupied.is_dir(), clock) == (
        CredentialLockTimeoutError(occupied, 7.5),
        True,
        Clock(7.5),
    )


def test_claude_credential_lock_keeps_live_client_locks_fresh(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    lock = ClaudeCredentialRefreshLock(configuration, update_seconds=0.01)

    with lock:
        current = configuration / ".oauth_refresh.lock"
        initial_mtime = current.stat().st_mtime_ns
        deadline = time.monotonic() + 1
        while current.stat().st_mtime_ns == initial_mtime:
            if time.monotonic() >= deadline:
                pytest.fail("the held lock did not receive a heartbeat")
            time.sleep(0.01)
        refreshed_mtime = current.stat().st_mtime_ns

    assert (
        refreshed_mtime > initial_mtime,
        tuple(path.name for path in configuration.iterdir()),
        Path(f"{configuration.resolve()}.lock").exists(),
    ) == (True, (), False)


def test_claude_credential_lock_preserves_a_replacement_owner(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    current = configuration / ".oauth_refresh.lock"
    displaced = configuration / "displaced.lock"
    lock = ClaudeCredentialRefreshLock(configuration)

    with pytest.raises(CredentialLockCompromisedError) as raised, lock:
        current.rename(displaced)
        current.mkdir()
        lock.check()

    assert (
        raised.value,
        tuple(sorted(path.name for path in configuration.iterdir())),
        Path(f"{configuration.resolve()}.lock").exists(),
    ) == (
        CredentialLockCompromisedError(current),
        (".oauth_refresh.lock", "displaced.lock"),
        False,
    )


def test_claude_credential_lock_ignores_late_ownership_loss_on_exit(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    current = configuration / ".oauth_refresh.lock"
    displaced = configuration / "displaced.lock"

    with ClaudeCredentialRefreshLock(configuration):
        current.rename(displaced)
        current.mkdir()

    assert tuple(sorted(path.name for path in configuration.iterdir())) == (
        ".oauth_refresh.lock",
        "displaced.lock",
    )


def test_claude_credential_lock_ignores_release_failure_on_exit(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    current = configuration / ".storage-write.lock"

    with ClaudeCredentialStorageLock(configuration):
        (current / "occupied").write_text("prevent release")

    assert {
        path.relative_to(configuration): (path.read_text() if path.is_file() else None)
        for path in configuration.rglob("*")
    } == {
        Path(".storage-write.lock"): None,
        Path(".storage-write.lock/occupied"): "prevent release",
    }


def test_claude_refresh_lock_releases_other_paths_after_one_release_fails(
    tmp_path: Path,
) -> None:
    configuration = tmp_path / "configuration"
    primary = configuration / ".oauth_refresh.lock"
    legacy = Path(f"{configuration.resolve()}.lock")

    with ClaudeCredentialRefreshLock(configuration):
        (legacy / "occupied").write_text("prevent release")

    after_failed_release = {
        path: (path.read_text() if path.is_file() else None)
        for path in (*configuration.rglob("*"), legacy, *legacy.rglob("*"))
    }

    (legacy / "occupied").unlink()
    legacy.rmdir()
    with ClaudeCredentialRefreshLock(configuration):
        reacquired = (primary.is_dir(), legacy.is_dir())

    assert (after_failed_release, reacquired, primary.exists(), legacy.exists()) == (
        {
            legacy: None,
            legacy / "occupied": "prevent release",
        },
        (True, True),
        False,
        False,
    )
