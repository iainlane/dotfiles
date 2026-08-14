"""Run-scoped Codex subscription authentication and refresh coordination."""

import base64
import binascii
import errno
import os
import stat
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from queue import Empty, Queue
from threading import Event, Lock, Thread, current_thread
from time import monotonic
from typing import Protocol

import httpx
import msgspec
from watchfiles import watch

from .credential_lock import CodexCredentialStorageLock
from .errors import CodexRuntimeError
from .models import SecretFileDescriptor
from .ports import CancellationSignal, CredentialLock
from .protocols.codex_auth import (
    CodexAccessCredential,
    CodexHostCredentialProjection,
    CodexOAuthFailure,
    CodexOAuthFlatFailureDocument,
    CodexOAuthNestedFailureDocument,
    CodexOAuthRefreshRequest,
    CodexOAuthRefreshResponse,
    CodexTokenData,
)
from .storage import synchronise_directory


@dataclass(eq=True)
class CodexHomeMissingError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"configured Codex home does not exist: {self.source}"


@dataclass(eq=True)
class CodexHomeResolveError(CodexRuntimeError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not resolve configured Codex home {self.source}: {self.cause}"


@dataclass(eq=True)
class CodexHomeSymlinkLoopError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"configured Codex home contains a symlink loop: {self.source}"


@dataclass(eq=True)
class CodexHomeTypeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"configured Codex home is not a directory: {self.source}"


@dataclass(eq=True)
class CodexCredentialFileReadError(CodexRuntimeError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read Codex credential {self.source}: {self.cause}"


@dataclass(eq=True)
class CodexCredentialDecodeError(CodexRuntimeError):
    source: Path
    cause: msgspec.DecodeError

    def __str__(self) -> str:
        return f"could not decode Codex credential {self.source}: {self.cause}"


@dataclass(eq=True)
class CodexSubscriptionTokensMissingError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex credential does not contain subscription tokens: {self.source}"


@dataclass(eq=True)
class CodexCredentialRefreshTimestampMissingError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex credential does not contain a refresh timestamp: {self.source}"


@dataclass(eq=True)
class CodexCredentialFileWriteError(CodexRuntimeError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not update Codex credential {self.destination}: {self.cause}"


@dataclass(eq=True)
class CodexCredentialJwtShapeError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"Codex credential has no usable workspace claim: {self.source}"


@dataclass(eq=True)
class CodexCredentialJwtClaimsDecodeError(CodexRuntimeError):
    source: Path
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"Codex credential contains invalid JWT claims: {self.source}"


@dataclass(eq=True)
class CodexOAuthRefreshTransportError(CodexRuntimeError):
    cause: httpx.HTTPError

    def __str__(self) -> str:
        return f"Codex OAuth refresh transport failed: {self.cause}"


@dataclass(eq=True)
class CodexOAuthRefreshUnexpectedError(CodexRuntimeError):
    cause: Exception

    def __str__(self) -> str:
        return f"Codex OAuth refresh failed unexpectedly: {self.cause}"


@dataclass(eq=True)
class CodexOAuthRefreshWorkerStartError(CodexRuntimeError):
    cause: RuntimeError

    def __str__(self) -> str:
        return f"could not start the Codex refresh transaction: {self.cause}"


@dataclass(eq=True)
class CodexCredentialRotationDeadlineError(CodexRuntimeError):
    seconds: float

    def __str__(self) -> str:
        return (
            f"a competing Codex process did not publish its rotated credential "
            f"within the app-server's {self.seconds:g}-second client deadline"
        )


@dataclass(eq=True)
class CodexCredentialRotationObserverError(CodexRuntimeError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"could not observe competing Codex credential rotation: {self.source}"


@dataclass(eq=True)
class CodexOAuthRefreshCancelledError(CodexRuntimeError):
    def __str__(self) -> str:
        return "Codex OAuth refresh was cancelled with the suite run"


@dataclass(eq=True)
class CodexOAuthRefreshDecodeError(CodexRuntimeError):
    status: int
    cause: msgspec.DecodeError | msgspec.ValidationError

    def __str__(self) -> str:
        return f"Codex OAuth refresh returned invalid JSON with status {self.status}"


@dataclass(eq=True)
class CodexOAuthRefreshRejectedError(CodexRuntimeError):
    status: int
    failure: CodexOAuthFailure

    def __str__(self) -> str:
        return (
            f"Codex OAuth refresh was rejected with status {self.status}: "
            f"{self.failure.code or 'unknown error'}"
        )


@dataclass(eq=True)
class CodexOAuthRefreshAccessTokenMissingError(CodexRuntimeError):
    def __str__(self) -> str:
        return "Codex OAuth refresh returned no access token"


@dataclass(eq=True)
class CodexSubscriptionAccountChangedError(CodexRuntimeError):
    expected: str
    actual: str

    def __str__(self) -> str:
        return (
            f"Codex subscription account changed from {self.expected!r} "
            f"to {self.actual!r} during the run"
        )


@dataclass(eq=True)
class CodexCredentialStateDirectoryCreateError(CodexRuntimeError):
    directory: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not create isolated Codex state directory {self.directory}: {self.cause}"


@dataclass(eq=True)
class CodexCredentialStateDirectoryOpenError(CodexRuntimeError):
    directory: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not open isolated Codex state directory {self.directory}: {self.cause}"


@dataclass(eq=True)
class CodexCredentialStateDirectoryUnsafeError(CodexRuntimeError):
    directory: Path

    def __str__(self) -> str:
        return (
            f"isolated Codex state directory is not a real directory: {self.directory}"
        )


@dataclass(eq=True)
class CodexInstanceCredentialRemoveError(CodexRuntimeError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not remove legacy isolated Codex credential {self.source}: {self.cause}"


_EXTERNAL_AUTH_REFRESH_DEADLINE_SECONDS = 8.0


@dataclass(frozen=True)
class _CodexRefreshSuccess:
    credential: CodexAccessCredential


@dataclass(frozen=True)
class _CodexRefreshFailure:
    error: CodexRuntimeError


@dataclass(frozen=True)
class _CodexRefreshCancelled:
    pass


type _CodexRefreshOutcome = (
    _CodexRefreshSuccess | _CodexRefreshFailure | _CodexRefreshCancelled
)


@dataclass
class RunCancellation:
    """Broadcast run cancellation without one waiting thread per callback."""

    _event: Event = field(default_factory=Event, repr=False)
    _lock: Lock = field(default_factory=Lock, repr=False)
    _subscribers: set[Queue[_CodexRefreshOutcome]] = field(
        default_factory=set,
        repr=False,
    )

    def set(self) -> None:
        with self._lock:
            self._event.set()
            subscribers = tuple(self._subscribers)
        for subscriber in subscribers:
            subscriber.put(_CodexRefreshCancelled())

    def is_set(self) -> bool:
        return self._event.is_set()

    def subscribe(self, subscriber: Queue[_CodexRefreshOutcome]) -> None:
        with self._lock:
            if self._event.is_set():
                subscriber.put(_CodexRefreshCancelled())
                return
            self._subscribers.add(subscriber)

    def unsubscribe(self, subscriber: Queue[_CodexRefreshOutcome]) -> None:
        with self._lock:
            self._subscribers.discard(subscriber)


class _CodexJwtAuthClaims(msgspec.Struct, frozen=True):
    chatgpt_account_id: str | None = None


class _CodexJwtClaims(msgspec.Struct, frozen=True):
    auth: _CodexJwtAuthClaims | None = msgspec.field(
        default=None,
        name="https://api.openai.com/auth",
    )


class CodexCredentialRotationOutcome(StrEnum):
    """Terminal result of waiting for another Codex process to persist auth."""

    CHANGED = "changed"
    CANCELLED = "cancelled"
    DEADLINE = "deadline"


class CodexCredentialRotationWaiter(Protocol):
    """Wait for a competing Codex process to replace `auth.json`."""

    def wait(
        self,
        source: Path,
        cancellation: CancellationSignal,
        deadline: float,
    ) -> CodexCredentialRotationOutcome: ...


@dataclass(frozen=True)
class CodexCredentialRotationObserver:
    """Wait for an ordinary or suite Codex process to replace `auth.json`."""

    def wait(
        self,
        source: Path,
        cancellation: CancellationSignal,
        deadline: float,
    ) -> CodexCredentialRotationOutcome:
        remaining_milliseconds = max(0, int((deadline - monotonic()) * 1_000))
        if remaining_milliseconds == 0:
            return CodexCredentialRotationOutcome.DEADLINE
        try:
            changes = watch(
                source.parent,
                watch_filter=lambda _, path: Path(path) == source,
                debounce=0,
                step=0,
                stop_event=cancellation,
                rust_timeout=remaining_milliseconds,
                yield_on_timeout=True,
                recursive=False,
            )
            for changed in changes:
                return (
                    CodexCredentialRotationOutcome.CHANGED
                    if changed
                    else CodexCredentialRotationOutcome.DEADLINE
                )
            return CodexCredentialRotationOutcome.CANCELLED
        except (OSError, RuntimeError) as error:
            raise CodexCredentialRotationObserverError(source, error) from error


def jwt_account_id(source: Path, token: str) -> str | None:
    """Read the workspace claim using the pinned client's JWT claim shape."""

    parts = token.split(".")
    if len(parts) != 3 or any(not part for part in parts):
        return None
    try:
        payload = base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
    except (binascii.Error, ValueError):
        return None
    try:
        claims = msgspec.json.decode(payload, type=_CodexJwtClaims)
    except (msgspec.DecodeError, msgspec.ValidationError) as error:
        raise CodexCredentialJwtClaimsDecodeError(source, error) from error
    return claims.auth.chatgpt_account_id if claims.auth is not None else None


@dataclass(frozen=True)
class CodexCredential:
    """Typed subscription fields plus the complete host document to preserve."""

    document: dict[str, object] = field(repr=False)
    tokens: CodexTokenData
    last_refresh: str

    @classmethod
    def decode(cls, source: Path, value: bytes) -> "CodexCredential":
        """Decode known authentication fields while retaining unknown fields."""

        try:
            document = msgspec.json.decode(value, type=dict[str, object])
            projection = msgspec.json.decode(
                value,
                type=CodexHostCredentialProjection,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexCredentialDecodeError(source, error) from error

        if projection.tokens is None:
            raise CodexSubscriptionTokensMissingError(source)
        if projection.last_refresh is None:
            raise CodexCredentialRefreshTimestampMissingError(source)
        account_id = projection.tokens.account_id
        if account_id is None:
            account_id = jwt_account_id(source, projection.tokens.access_token)
        if account_id is None:
            account_id = jwt_account_id(source, projection.tokens.id_token)
        if account_id is None:
            raise CodexCredentialJwtShapeError(source)
        return cls(
            document,
            CodexTokenData(
                id_token=projection.tokens.id_token,
                access_token=projection.tokens.access_token,
                refresh_token=projection.tokens.refresh_token,
                account_id=account_id,
            ),
            projection.last_refresh,
        )

    def refreshed(
        self,
        response: CodexOAuthRefreshResponse,
        refreshed_at: datetime,
    ) -> "CodexCredential":
        """Apply a successful OAuth response without dropping host-owned fields."""

        if response.access_token is None:
            raise CodexOAuthRefreshAccessTokenMissingError

        tokens = CodexTokenData(
            id_token=response.id_token or self.tokens.id_token,
            access_token=response.access_token,
            refresh_token=response.refresh_token or self.tokens.refresh_token,
            account_id=self.tokens.account_id,
        )
        document = dict(self.document)
        document["tokens"] = msgspec.to_builtins(tokens)
        timestamp = refreshed_at.astimezone(UTC).isoformat().replace("+00:00", "Z")
        document["last_refresh"] = timestamp
        return CodexCredential(document, tokens, timestamp)

    def access(self) -> CodexAccessCredential:
        """Project the non-refreshable fields accepted by Codex app-server."""

        return CodexAccessCredential(
            self.tokens.access_token,
            self.tokens.account_id,
        )


@dataclass(frozen=True)
class CodexFileCredentialStore:
    """Load and atomically reconcile the ordinary Codex credential file."""

    source: Path
    lock: Callable[[Path], CredentialLock] = field(
        default=CodexCredentialStorageLock,
        repr=False,
    )

    def load(self) -> CodexCredential:
        try:
            value = self.source.read_bytes()
        except OSError as error:
            raise CodexCredentialFileReadError(self.source, error) from error
        return CodexCredential.decode(self.source, value)

    def reconcile(
        self,
        original: CodexCredential,
        replacement: CodexCredential,
    ) -> CodexCredential:
        """Persist replacement tokens unless another owner already rotated them."""

        # An interactive Codex can rotate `auth.json` between the comparison and
        # the replace, so the whole read-compare-write runs under one lock.
        lock = self.lock(self.source.parent)
        with lock:
            current = self.load()
            if current.tokens.refresh_token != original.tokens.refresh_token:
                return current

            reconciled = CodexCredential(
                document={
                    **current.document,
                    "tokens": msgspec.to_builtins(replacement.tokens),
                    "last_refresh": replacement.last_refresh,
                },
                tokens=replacement.tokens,
                last_refresh=replacement.last_refresh,
            )
            lock.check()
            self._write(reconciled)
            return reconciled

    def _write(self, credential: CodexCredential) -> None:
        descriptor: int | None = None
        temporary: Path | None = None
        failure: OSError | None = None
        try:
            descriptor, name = tempfile.mkstemp(dir=self.source.parent)
            temporary = Path(name)
            with os.fdopen(descriptor, "wb") as stream:
                descriptor = None
                stream.write(msgspec.json.encode(credential.document))
                stream.flush()
                os.fsync(stream.fileno())
            temporary.chmod(0o600)
            temporary.replace(self.source)
            temporary = None
            synchronise_directory(self.source.parent)
        except OSError as error:
            failure = error
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError as error:
                    if failure is None:
                        failure = error
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError as error:
                    if failure is None:
                        failure = error
        if failure is not None:
            raise CodexCredentialFileWriteError(self.source, failure) from failure


@dataclass(frozen=True)
class CodexOAuthRefresher:
    """Refresh Codex tokens using the pinned client's OAuth contract."""

    token_url: str
    client_id: str
    transport: httpx.BaseTransport | None = field(default=None, repr=False)

    def refresh(
        self,
        refresh_token: str,
    ) -> CodexOAuthRefreshResponse:
        """Refresh synchronously so a successful token rotation cannot be abandoned."""

        request = CodexOAuthRefreshRequest(
            client_id=self.client_id,
            grant_type="refresh_token",
            refresh_token=refresh_token,
        )
        try:
            with httpx.Client(
                transport=self.transport,
                timeout=_EXTERNAL_AUTH_REFRESH_DEADLINE_SECONDS,
            ) as client:
                response = client.post(
                    self.token_url,
                    headers={"Content-Type": "application/json"},
                    content=msgspec.json.encode(request),
                )
        except httpx.HTTPError as error:
            raise CodexOAuthRefreshTransportError(error) from error
        except RuntimeError as error:
            raise CodexOAuthRefreshUnexpectedError(error) from error

        if response.is_success:
            try:
                decoded = msgspec.json.decode(
                    response.content,
                    type=CodexOAuthRefreshResponse,
                )
            except (msgspec.DecodeError, msgspec.ValidationError) as error:
                raise CodexOAuthRefreshDecodeError(
                    response.status_code, error
                ) from error
            return decoded

        raise CodexOAuthRefreshRejectedError(
            response.status_code,
            self._decode_failure(response),
        )

    @staticmethod
    def _decode_failure(response: httpx.Response) -> CodexOAuthFailure:
        try:
            nested = msgspec.json.decode(
                response.content,
                type=CodexOAuthNestedFailureDocument,
            )
        except (msgspec.DecodeError, msgspec.ValidationError):
            pass
        else:
            return CodexOAuthFailure(nested.error.code, nested.error.message)

        try:
            flat = msgspec.json.decode(
                response.content,
                type=CodexOAuthFlatFailureDocument,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise CodexOAuthRefreshDecodeError(response.status_code, error) from error
        return CodexOAuthFailure(flat.error, flat.error_description)


@dataclass
class CodexHostIdentity:
    """Provide external app-server auth backed by one run-scoped refresh broker."""

    store: CodexFileCredentialStore
    refresher: CodexOAuthRefresher
    credential: CodexCredential
    clock: Callable[[], datetime] = field(
        default=lambda: datetime.now(UTC),
        repr=False,
    )
    cancellation: RunCancellation = field(default_factory=RunCancellation, repr=False)
    rotation_observer: CodexCredentialRotationWaiter = field(
        default_factory=CodexCredentialRotationObserver,
        repr=False,
    )
    _lock: Lock = field(default_factory=Lock, init=False, repr=False)
    _refresh_lock: Lock = field(default_factory=Lock, init=False, repr=False)
    _transaction_lock: Lock = field(default_factory=Lock, init=False, repr=False)
    _transactions: set[Thread] = field(default_factory=set, init=False, repr=False)

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str],
        home: Path,
        token_url: str,
        client_id: str,
        cancellation: RunCancellation | None = None,
    ) -> "CodexHostIdentity":
        """Acquire the ordinary Codex login as the run's refresh authority."""

        configured_home = environment.get("CODEX_HOME")
        source = Path(configured_home) if configured_home else home / ".codex"
        resolved = cls._resolve_home(source)
        credential_source = cls._resolve_credential(resolved / "auth.json")
        store = CodexFileCredentialStore(credential_source)
        return cls(
            store,
            CodexOAuthRefresher(token_url, client_id),
            store.load(),
            cancellation=cancellation or RunCancellation(),
        )

    @staticmethod
    def _resolve_home(source: Path) -> Path:
        try:
            resolved = source.resolve(strict=True)
        except FileNotFoundError as error:
            raise CodexHomeMissingError(source) from error
        except OSError as error:
            raise CodexHomeResolveError(source, error) from error
        except RuntimeError as error:
            raise CodexHomeSymlinkLoopError(source) from error
        try:
            mode = resolved.stat().st_mode
        except OSError as error:
            raise CodexHomeResolveError(source, error) from error
        if not stat.S_ISDIR(mode):
            raise CodexHomeTypeError(source)
        return resolved

    @staticmethod
    def _resolve_credential(source: Path) -> Path:
        try:
            resolved = source.resolve(strict=True)
            mode = resolved.stat().st_mode
        except OSError as error:
            raise CodexCredentialFileReadError(source, error) from error
        except RuntimeError as error:
            raise CodexHomeSymlinkLoopError(source) from error
        if not stat.S_ISREG(mode):
            raise CodexCredentialFileReadError(
                source,
                OSError(errno.EINVAL, "credential is not a regular file"),
            )
        return resolved

    def authentication(self) -> CodexAccessCredential:
        """Return current host access while preserving the run's account identity."""

        with self._lock:
            return self._adopt(self.store.load()).access()

    def finish(self) -> None:
        """Cancel callbacks and retain the process until rotations are reconciled."""

        self.cancellation.set()
        while True:
            with self._transaction_lock:
                transactions = tuple(self._transactions)
            if not transactions:
                return
            for transaction in transactions:
                transaction.join()

    def refresh(
        self,
        rejected_access_token: str,
        expected_account_id: str | None,
    ) -> CodexAccessCredential:
        """Bound the callback while its worker remains responsible for persistence."""

        if self.cancellation.is_set():
            raise CodexOAuthRefreshCancelledError
        deadline = monotonic() + _EXTERNAL_AUTH_REFRESH_DEADLINE_SECONDS
        outcomes: Queue[_CodexRefreshOutcome] = Queue()
        refresh = Thread(
            target=self._run_refresh,
            args=(rejected_access_token, expected_account_id, deadline, outcomes),
            name="codex-auth-transaction",
            daemon=True,
        )
        try:
            with self._transaction_lock:
                self._transactions.add(refresh)
            self.cancellation.subscribe(outcomes)
            refresh.start()
        except RuntimeError as error:
            with self._transaction_lock:
                self._transactions.discard(refresh)
            self.cancellation.unsubscribe(outcomes)
            raise CodexOAuthRefreshWorkerStartError(error) from error
        try:
            outcome = outcomes.get(
                timeout=max(0, deadline - monotonic()),
            )
        except Empty as error:
            raise CodexCredentialRotationDeadlineError(
                _EXTERNAL_AUTH_REFRESH_DEADLINE_SECONDS
            ) from error
        finally:
            self.cancellation.unsubscribe(outcomes)
        match outcome:
            case _CodexRefreshSuccess(credential):
                return credential
            case _CodexRefreshFailure(error):
                raise error
            case _CodexRefreshCancelled():
                raise CodexOAuthRefreshCancelledError

    def _run_refresh(
        self,
        rejected_access_token: str,
        expected_account_id: str | None,
        deadline: float,
        outcomes: Queue[_CodexRefreshOutcome],
    ) -> None:
        try:
            credential = self._refresh_transaction(
                rejected_access_token,
                expected_account_id,
                deadline,
            )
        except CodexRuntimeError as error:
            outcomes.put(_CodexRefreshFailure(error))
        except RuntimeError as error:
            outcomes.put(_CodexRefreshFailure(CodexOAuthRefreshUnexpectedError(error)))
        else:
            outcomes.put(_CodexRefreshSuccess(credential))
        finally:
            with self._transaction_lock:
                self._transactions.discard(current_thread())

    def _refresh_transaction(
        self,
        rejected_access_token: str,
        expected_account_id: str | None,
        deadline: float,
    ) -> CodexAccessCredential:
        """Complete or reconcile one rotation even if the caller has gone away."""

        # One in-process rotation at a time: workers queueing here re-check the
        # store once the winner has persisted, so they adopt its rotation
        # instead of spending the refresh token on their own exchange.
        with self._refresh_lock:
            with self._lock:
                current = self._adopt(self.store.load())
                if current.tokens.access_token != rejected_access_token:
                    return current.access()
                if (
                    expected_account_id is not None
                    and expected_account_id != current.tokens.account_id
                ):
                    raise CodexSubscriptionAccountChangedError(
                        expected_account_id,
                        current.tokens.account_id,
                    )

            try:
                if self.cancellation.is_set():
                    raise CodexOAuthRefreshCancelledError
                response = self.refresher.refresh(current.tokens.refresh_token)
            except CodexOAuthRefreshRejectedError as error:
                with self._lock:
                    recovered = self._adopt(self.store.load())
                    if recovered.tokens.access_token != rejected_access_token:
                        return recovered.access()
                if error.failure.code != "refresh_token_reused":
                    raise
                return self._await_competing_rotation(
                    rejected_access_token,
                    deadline,
                )

            replacement = current.refreshed(response, self.clock())
            with self._lock:
                return self._adopt(self.store.reconcile(current, replacement)).access()

    def _await_competing_rotation(
        self,
        rejected_access_token: str,
        deadline: float,
    ) -> CodexAccessCredential:
        """Adopt a rotation won by an ordinary or suite Codex process."""

        outcome = self.rotation_observer.wait(
            self.store.source,
            self.cancellation,
            deadline,
        )
        if outcome is CodexCredentialRotationOutcome.CHANGED:
            with self._lock:
                recovered = self._adopt(self.store.load())
            if recovered.tokens.access_token != rejected_access_token:
                return recovered.access()
        with self._lock:
            recovered = self._adopt(self.store.load())
        if recovered.tokens.access_token != rejected_access_token:
            return recovered.access()
        if outcome is CodexCredentialRotationOutcome.CANCELLED:
            raise CodexOAuthRefreshCancelledError
        raise CodexCredentialRotationDeadlineError(
            _EXTERNAL_AUTH_REFRESH_DEADLINE_SECONDS
        )

    def _adopt(self, credential: CodexCredential) -> CodexCredential:
        expected = self.credential.tokens.account_id
        actual = credential.tokens.account_id
        if expected != actual:
            raise CodexSubscriptionAccountChangedError(expected, actual)
        self.credential = credential
        return credential

    def environment(self, state: Path) -> dict[str, str]:
        """Create an isolated Codex home containing configuration but no secrets."""

        instance_home = state / ".codex"
        try:
            instance_home.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise CodexCredentialStateDirectoryCreateError(
                instance_home, error
            ) from error
        try:
            mode = instance_home.lstat().st_mode
        except OSError as error:
            raise CodexCredentialStateDirectoryOpenError(
                instance_home, error
            ) from error
        if not stat.S_ISDIR(mode):
            raise CodexCredentialStateDirectoryUnsafeError(instance_home)

        legacy_credential = instance_home / "auth.json"
        try:
            legacy_credential.unlink(missing_ok=True)
        except OSError as error:
            raise CodexInstanceCredentialRemoveError(
                legacy_credential,
                error,
            ) from error

        return {"CODEX_HOME": str(instance_home), "HOME": str(state)}

    def secrets(self) -> tuple[SecretFileDescriptor, ...]:
        """External auth travels over the private app-server input stream."""

        return ()
