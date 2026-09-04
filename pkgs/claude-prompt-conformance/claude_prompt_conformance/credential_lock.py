"""Cross-process credential locking compatible with the pinned clients."""

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from os import stat_result
from pathlib import Path
from random import uniform
from threading import Event, Thread
from types import TracebackType

from .errors import ConformanceError


@dataclass(eq=True)
class CredentialLockTimeoutError(ConformanceError):
    path: Path
    timeout_seconds: float

    def __str__(self) -> str:
        return (
            f"the credential lock {self.path} remained busy for "
            f"{self.timeout_seconds:g} seconds"
        )


@dataclass(eq=True)
class CredentialLockAcquireError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not acquire the credential lock {self.path}: {self.cause}"


@dataclass(eq=True)
class CredentialLockUpdateError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not maintain the credential lock {self.path}: {self.cause}"


@dataclass(eq=True)
class CredentialLockHeartbeatStartError(ConformanceError):
    cause: RuntimeError

    def __str__(self) -> str:
        return "could not start the credential lock heartbeat"


@dataclass(eq=True)
class CredentialLockCompromisedError(ConformanceError):
    path: Path

    def __str__(self) -> str:
        return f"the credential lock {self.path} changed while held"


@dataclass(eq=True)
class CredentialLockReleaseError(ConformanceError):
    path: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not release the credential lock {self.path}: {self.cause}"


_LOCK_NAME = ".oauth_refresh.lock"
_STORAGE_LOCK_NAME = ".storage-write.lock"
_CODEX_STORAGE_LOCK_NAME = ".auth-write.lock"
_STALE_SECONDS = 60
_STORAGE_STALE_SECONDS = 15
_UPDATE_SECONDS = 5
_ACQUISITION_ATTEMPTS = 6
_STORAGE_ACQUISITION_ATTEMPTS = 11
_LOGGER = logging.getLogger(__name__)


def _retry_delay(_attempt: int) -> float:
    return uniform(1, 2)


def _storage_retry_delay(attempt: int) -> float:
    return min(0.1 * (2**attempt), 1)


@dataclass(frozen=True)
class _LockBusy(Exception):
    path: Path


@dataclass(frozen=True)
class _HeldLock:
    path: Path
    device: int
    inode: int

    @classmethod
    def from_stat(cls, path: Path, value: stat_result) -> "_HeldLock":
        return cls(path, value.st_dev, value.st_ino)

    def matches(self, value: stat_result) -> bool:
        return (value.st_dev, value.st_ino) == (self.device, self.inode)


class _CredentialDirectoryLock:
    """Hold one or more client-compatible cross-process directory locks."""

    def __init__(
        self,
        configuration_directory: Path,
        required_paths: tuple[Path, ...],
        optional_paths: tuple[Path, ...],
        acquisition_attempts: int = _ACQUISITION_ATTEMPTS,
        retry_seconds: Callable[[int], float] = _retry_delay,
        stale_seconds: float = _STALE_SECONDS,
        update_seconds: float = _UPDATE_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._configuration_directory = configuration_directory
        self._required_paths = required_paths
        self._optional_paths = optional_paths
        self._acquisition_attempts = acquisition_attempts
        self._retry_seconds = retry_seconds
        self._stale_seconds = stale_seconds
        self._update_seconds = update_seconds
        self._monotonic = monotonic
        self._wall_clock = wall_clock
        self._sleep = sleep
        self._held: list[_HeldLock] = []
        self._heartbeat_stop = Event()
        self._heartbeat: Thread | None = None
        self._failure: (
            CredentialLockCompromisedError
            | CredentialLockReleaseError
            | CredentialLockUpdateError
            | None
        ) = None

    def __enter__(self) -> None:
        """Acquire the configured lock paths used by the pinned client."""

        try:
            self._configuration_directory.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise CredentialLockAcquireError(
                self._configuration_directory,
                error,
            ) from error

        self._failure = None
        started_at = self._monotonic()
        for attempt in range(self._acquisition_attempts):
            try:
                for path in self._required_paths:
                    self._acquire(path)
                for path in self._optional_paths:
                    try:
                        self._acquire(path)
                    except CredentialLockAcquireError:
                        # Claude Code treats legacy locks as best-effort when
                        # their paths are unusable rather than contended.
                        continue
            except _LockBusy as busy:
                self._release()
                if attempt + 1 == self._acquisition_attempts:
                    raise CredentialLockTimeoutError(
                        busy.path,
                        self._monotonic() - started_at,
                    ) from None
                self._sleep(self._retry_seconds(attempt))
                continue
            except BaseException:
                self._release()
                raise
            break

        self._heartbeat_stop.clear()
        self._heartbeat = Thread(
            target=self._maintain,
            name="claude-credential-lock-heartbeat",
            daemon=True,
        )
        try:
            self._heartbeat.start()
        except RuntimeError as error:
            self._heartbeat = None
            self._release()
            raise CredentialLockHeartbeatStartError(error) from error

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Release every acquired lock in reverse acquisition order."""

        self._heartbeat_stop.set()
        if self._heartbeat is not None:
            self._heartbeat.join()
            self._heartbeat = None
        try:
            self._release()
        except (
            CredentialLockCompromisedError,
            CredentialLockReleaseError,
            CredentialLockUpdateError,
        ) as error:
            _LOGGER.debug("credential lock cleanup failed", exc_info=error)

    def check(self) -> None:
        """Fail before persistence if another process displaced a held lock."""

        if self._failure is not None:
            raise self._failure

        for held in self._held:
            try:
                value = held.path.stat()
            except OSError as error:
                raise CredentialLockUpdateError(held.path, error) from error
            if not held.matches(value):
                raise CredentialLockCompromisedError(held.path)

    def _acquire(self, path: Path) -> None:
        while True:
            try:
                path.mkdir()
            except FileExistsError:
                if self._reclaim_stale(path):
                    continue
                raise _LockBusy(path) from None
            except OSError as error:
                raise CredentialLockAcquireError(path, error) from error

            try:
                value = path.stat()
            except OSError as error:
                raise CredentialLockAcquireError(path, error) from error
            self._held.append(_HeldLock.from_stat(path, value))
            return

    def _reclaim_stale(self, path: Path) -> bool:
        try:
            value = path.stat()
        except FileNotFoundError:
            return True
        except OSError as error:
            raise CredentialLockAcquireError(path, error) from error
        if self._wall_clock() - value.st_mtime < self._stale_seconds:
            return False

        try:
            path.rmdir()
        except FileNotFoundError:
            return True
        except OSError as error:
            raise CredentialLockAcquireError(path, error) from error
        return True

    def _maintain(self) -> None:
        while not self._heartbeat_stop.wait(self._update_seconds):
            for held in self._held:
                try:
                    value = held.path.stat()
                    if not held.matches(value):
                        self._failure = CredentialLockCompromisedError(held.path)
                        return
                    held.path.touch()
                except OSError as error:
                    self._failure = CredentialLockUpdateError(
                        held.path,
                        error,
                    )
                    return

    def _release(self) -> None:
        while self._held:
            held = self._held.pop()
            try:
                value = held.path.stat()
            except FileNotFoundError:
                self._failure = self._failure or CredentialLockCompromisedError(
                    held.path
                )
                continue
            except OSError as error:
                self._failure = self._failure or CredentialLockReleaseError(
                    held.path,
                    error,
                )
                continue
            if not held.matches(value):
                self._failure = self._failure or CredentialLockCompromisedError(
                    held.path
                )
                continue
            try:
                held.path.rmdir()
            except OSError as error:
                self._failure = self._failure or CredentialLockReleaseError(
                    held.path,
                    error,
                )

        if self._failure is not None:
            raise self._failure


class ClaudeCredentialRefreshLock(_CredentialDirectoryLock):
    """Serialize OAuth refresh ownership with the pinned Claude client."""

    def __init__(
        self,
        configuration_directory: Path,
        acquisition_attempts: int = _ACQUISITION_ATTEMPTS,
        retry_seconds: Callable[[int], float] = _retry_delay,
        stale_seconds: float = _STALE_SECONDS,
        update_seconds: float = _UPDATE_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        super().__init__(
            configuration_directory,
            (configuration_directory / _LOCK_NAME,),
            (Path(f"{configuration_directory.resolve()}.lock"),),
            acquisition_attempts,
            retry_seconds,
            stale_seconds,
            update_seconds,
            monotonic,
            wall_clock,
            sleep,
        )


class ClaudeCredentialStorageLock(_CredentialDirectoryLock):
    """Serialize credential document writes with the pinned Claude client."""

    def __init__(
        self,
        configuration_directory: Path,
        acquisition_attempts: int = _STORAGE_ACQUISITION_ATTEMPTS,
        retry_seconds: Callable[[int], float] = _storage_retry_delay,
        stale_seconds: float = _STORAGE_STALE_SECONDS,
        update_seconds: float = _UPDATE_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        super().__init__(
            configuration_directory,
            (configuration_directory / _STORAGE_LOCK_NAME,),
            (),
            acquisition_attempts,
            retry_seconds,
            stale_seconds,
            update_seconds,
            monotonic,
            wall_clock,
            sleep,
        )


class CodexCredentialStorageLock(_CredentialDirectoryLock):
    """Serialize `auth.json` rotations against an ordinary Codex client."""

    def __init__(
        self,
        credential_directory: Path,
        acquisition_attempts: int = _STORAGE_ACQUISITION_ATTEMPTS,
        retry_seconds: Callable[[int], float] = _storage_retry_delay,
        stale_seconds: float = _STORAGE_STALE_SECONDS,
        update_seconds: float = _UPDATE_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        super().__init__(
            credential_directory,
            (credential_directory / _CODEX_STORAGE_LOCK_NAME,),
            (),
            acquisition_attempts,
            retry_seconds,
            stale_seconds,
            update_seconds,
            monotonic,
            wall_clock,
            sleep,
        )
