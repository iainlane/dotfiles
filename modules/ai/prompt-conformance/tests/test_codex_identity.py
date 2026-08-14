import base64
import json
import os
import stat
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from threading import Event
from types import TracebackType

import httpx
import msgspec
import pytest

import claude_prompt_conformance.codex_identity as codex_runtime
from claude_prompt_conformance.codex_identity import (
    CodexCredential,
    CodexCredentialRotationDeadlineError,
    CodexCredentialRotationOutcome,
    CodexFileCredentialStore,
    CodexHostIdentity,
    CodexOAuthRefreshCancelledError,
    CodexOAuthRefresher,
    CodexOAuthRefreshUnexpectedError,
    CodexSubscriptionAccountChangedError,
    RunCancellation,
)
from claude_prompt_conformance.credential_lock import (
    CodexCredentialStorageLock,
    CredentialLockTimeoutError,
)
from claude_prompt_conformance.ports import CancellationSignal
from claude_prompt_conformance.protocols.codex_auth import (
    CodexAccessCredential,
    CodexOAuthRefreshResponse,
)


class RotationOutcome:
    def __init__(
        self,
        outcome: CodexCredentialRotationOutcome,
        replacement: tuple[Path, dict[str, object]] | None = None,
    ) -> None:
        self.outcome = outcome
        self.replacement = replacement

    def wait(
        self,
        source: Path,
        cancellation: CancellationSignal,
        deadline: float,
    ) -> CodexCredentialRotationOutcome:
        if self.replacement is not None:
            destination, document = self.replacement
            destination.write_text(json.dumps(document))
        return self.outcome


@dataclass
class RecordingLock:
    """Observe the lock a credential store holds around one reconciliation."""

    directories: list[Path] = field(default_factory=list)
    events: list[str] = field(default_factory=list)

    def open(self, directory: Path) -> "RecordingLock":
        self.directories.append(directory)
        return self

    def __enter__(self) -> None:
        self.events.append("enter")

    def check(self) -> None:
        self.events.append("check")

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.events.append("exit")


@dataclass
class Clock:
    current: float = 0

    def monotonic(self) -> float:
        return self.current

    def sleep(self, seconds: float) -> None:
        self.current += seconds


def rotation(
    store: CodexFileCredentialStore,
) -> tuple[CodexCredential, CodexCredential]:
    """Pair the stored credential with the rotation a refresh would produce."""

    original = store.load()
    replacement = original.refreshed(
        CodexOAuthRefreshResponse(
            id_token="fresh-id",
            access_token="fresh-access",
            refresh_token="rotated-refresh",
        ),
        datetime(2026, 8, 13, 12, 34, 56, tzinfo=UTC),
    )
    return original, replacement


def token(account_id: str | None = None) -> str:
    claims: dict[str, object] = {}
    if account_id is not None:
        claims["https://api.openai.com/auth"] = {"chatgpt_account_id": account_id}
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=")
    return f"header.{payload.decode()}.signature"


def credential_document(
    access_token: str,
    refresh_token: str,
    *,
    account_id: str = "subscription-account",
) -> dict[str, object]:
    return {
        "tokens": {
            "id_token": "id-token",
            "access_token": access_token,
            "refresh_token": refresh_token,
            "account_id": account_id,
        },
        "last_refresh": "2026-08-13T00:00:00Z",
        "future_auth_field": {"preserved": True},
    }


def identity(
    source: Path,
    exchange: httpx.MockTransport,
) -> CodexHostIdentity:
    store = CodexFileCredentialStore(source)
    return CodexHostIdentity(
        store,
        CodexOAuthRefresher(
            "https://codex.invalid/oauth/token",
            "codex-client",
            transport=exchange,
        ),
        store.load(),
        clock=lambda: datetime(2026, 8, 13, 12, 34, 56, tzinfo=UTC),
    )


def test_codex_identity_exposes_access_without_persisting_instance_credentials(
    tmp_path: Path,
) -> None:
    source = tmp_path / "host" / "auth.json"
    source.parent.mkdir()
    source.write_text(json.dumps(credential_document("access", "refresh")))
    broker = identity(
        source,
        httpx.MockTransport(lambda _: httpx.Response(500)),
    )
    state = tmp_path / "instance"
    state.mkdir()

    assert (
        broker.authentication(),
        broker.environment(state),
        broker.secrets(),
        tuple(sorted(path.relative_to(state) for path in state.rglob("*"))),
    ) == (
        CodexAccessCredential("access", "subscription-account"),
        {
            "CODEX_HOME": str(state / ".codex"),
            "HOME": str(state),
        },
        (),
        (Path(".codex"),),
    )


def test_codex_identity_supports_subscription_tokens_without_a_workspace_id(
    tmp_path: Path,
) -> None:
    source = tmp_path / "host" / "auth.json"
    source.parent.mkdir()
    source.write_text(
        json.dumps(
            {
                "tokens": {
                    "id_token": token("subscription-account"),
                    "access_token": "opaque-access-token",
                    "refresh_token": "refresh",
                },
                "last_refresh": "2026-08-13T00:00:00Z",
            }
        )
    )
    broker = identity(
        source,
        httpx.MockTransport(lambda _: httpx.Response(500)),
    )

    assert broker.authentication() == CodexAccessCredential(
        "opaque-access-token",
        "subscription-account",
    )


def test_codex_identity_shares_one_refresh_and_preserves_the_host_document(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        # Keep the exchange slow enough that every unserialised worker would
        # start its own exchange before the first rotation lands in the store.
        time.sleep(0.05)
        return httpx.Response(
            200,
            json={
                "id_token": "fresh-id",
                "access_token": "fresh-access",
                "refresh_token": "rotated-refresh",
            },
        )

    broker = identity(source, httpx.MockTransport(exchange))
    with ThreadPoolExecutor(max_workers=4) as executor:
        results = tuple(
            executor.map(
                lambda _: broker.refresh("rejected", "subscription-account"),
                range(4),
            )
        )

    assert (
        results,
        msgspec.json.decode(source.read_bytes()),
        requests,
        source.stat().st_mode & 0o777,
    ) == (
        (CodexAccessCredential("fresh-access", "subscription-account"),) * 4,
        {
            "tokens": {
                "id_token": "fresh-id",
                "access_token": "fresh-access",
                "refresh_token": "rotated-refresh",
                "account_id": "subscription-account",
            },
            "last_refresh": "2026-08-13T12:34:56Z",
            "future_auth_field": {"preserved": True},
        },
        [
            {
                "client_id": "codex-client",
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
            }
        ],
        0o600,
    )


def test_codex_refresh_respects_app_servers_external_auth_deadline(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    request_extensions: list[dict[str, object]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        request_extensions.append(request.extensions)
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-access",
                "refresh_token": "fresh-refresh",
            },
        )

    broker = identity(source, httpx.MockTransport(exchange))

    assert (
        broker.refresh("rejected", "subscription-account"),
        request_extensions,
    ) == (
        CodexAccessCredential("fresh-access", "subscription-account"),
        [
            {
                "timeout": {
                    "connect": 8.0,
                    "read": 8.0,
                    "write": 8.0,
                    "pool": 8.0,
                }
            }
        ],
    )


def test_codex_refresh_cancellation_before_transport_preserves_the_credential(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    requests: list[httpx.Request] = []
    broker = identity(
        source,
        httpx.MockTransport(
            lambda request: (requests.append(request), httpx.Response(500))[1]
        ),
    )
    broker.cancellation.set()

    with pytest.raises(CodexOAuthRefreshCancelledError) as raised:
        broker.refresh("rejected", "subscription-account")

    assert (
        raised.value,
        msgspec.json.decode(source.read_bytes()),
        requests,
    ) == (
        CodexOAuthRefreshCancelledError(),
        credential_document("rejected", "refresh"),
        [],
    )


def test_codex_refresh_persists_a_completed_rotation_before_cancelling(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    cancellation = RunCancellation()
    started = Event()
    release = Event()

    def exchange(_: httpx.Request) -> httpx.Response:
        started.set()
        release.wait()
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-access",
                "refresh_token": "fresh-refresh",
            },
        )

    broker = identity(source, httpx.MockTransport(exchange))
    broker.cancellation = cancellation

    def cancel_started_refresh() -> None:
        started.wait()
        cancellation.set()

    with ThreadPoolExecutor(max_workers=1) as executor:
        cancelled = executor.submit(cancel_started_refresh)
        with pytest.raises(CodexOAuthRefreshCancelledError) as raised:
            broker.refresh("rejected", "subscription-account")
        release.set()
        cancelled.result()
    broker.finish()
    persisted = broker.authentication()

    assert (
        raised.value,
        persisted,
        msgspec.json.decode(source.read_bytes()),
    ) == (
        CodexOAuthRefreshCancelledError(),
        CodexAccessCredential("fresh-access", "subscription-account"),
        credential_document("fresh-access", "fresh-refresh")
        | {"last_refresh": "2026-08-13T12:34:56Z"},
    )


def test_codex_refresh_wraps_unexpected_transport_failures(tmp_path: Path) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    failure = RuntimeError("transport implementation failed")
    broker = identity(
        source,
        httpx.MockTransport(lambda _: (_ for _ in ()).throw(failure)),
    )

    with pytest.raises(CodexOAuthRefreshUnexpectedError) as raised:
        broker.refresh("rejected", "subscription-account")

    assert raised.value == CodexOAuthRefreshUnexpectedError(failure)


def test_codex_identity_adopts_a_host_rotation_before_refreshing(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    requests: list[dict[str, str]] = []
    broker = identity(
        source,
        httpx.MockTransport(
            lambda request: (
                requests.append(msgspec.json.decode(request.content)),
                httpx.Response(500),
            )[1]
        ),
    )
    source.write_text(json.dumps(credential_document("host-fresh", "host-refresh")))

    assert (
        broker.refresh("rejected", "subscription-account"),
        msgspec.json.decode(source.read_bytes()),
        requests,
    ) == (
        CodexAccessCredential("host-fresh", "subscription-account"),
        credential_document("host-fresh", "host-refresh"),
        [],
    )


def test_codex_identity_recovers_when_another_process_wins_the_refresh_race(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))

    def exchange(_: httpx.Request) -> httpx.Response:
        source.write_text(
            json.dumps(credential_document("host-winner", "host-rotated"))
        )
        return httpx.Response(
            400,
            json={"error": {"code": "refresh_token_reused"}},
        )

    broker = identity(source, httpx.MockTransport(exchange))

    assert (
        broker.refresh("rejected", "subscription-account"),
        msgspec.json.decode(source.read_bytes()),
    ) == (
        CodexAccessCredential("host-winner", "subscription-account"),
        credential_document("host-winner", "host-rotated"),
    )


def test_codex_identity_waits_for_an_ordinary_codex_refresh_winner(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    broker = identity(
        source,
        httpx.MockTransport(
            lambda _: httpx.Response(
                400,
                json={"error": {"code": "refresh_token_reused"}},
            )
        ),
    )
    broker.rotation_observer = RotationOutcome(
        CodexCredentialRotationOutcome.CHANGED,
        (source, credential_document("host-winner", "host-rotated")),
    )

    assert (
        broker.refresh("rejected", "subscription-account"),
        msgspec.json.decode(source.read_bytes()),
    ) == (
        CodexAccessCredential("host-winner", "subscription-account"),
        credential_document("host-winner", "host-rotated"),
    )


def test_codex_identity_reports_an_unpublished_competing_rotation(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    broker = identity(
        source,
        httpx.MockTransport(
            lambda _: httpx.Response(
                400,
                json={"error": {"code": "refresh_token_reused"}},
            )
        ),
    )
    broker.rotation_observer = RotationOutcome(CodexCredentialRotationOutcome.DEADLINE)

    with pytest.raises(CodexCredentialRotationDeadlineError) as raised:
        broker.refresh("rejected", "subscription-account")

    assert (
        raised.value,
        msgspec.json.decode(source.read_bytes()),
    ) == (
        CodexCredentialRotationDeadlineError(8),
        credential_document("rejected", "refresh"),
    )


def test_codex_store_holds_a_cross_process_lock_across_reconciliation(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    lock = RecordingLock()
    store = CodexFileCredentialStore(source, lock.open)
    original, replacement = rotation(store)

    reconciled = store.reconcile(original, replacement)

    assert (
        reconciled.tokens.access_token,
        lock.directories,
        lock.events,
        msgspec.json.decode(source.read_bytes()),
    ) == (
        "fresh-access",
        [tmp_path],
        ["enter", "check", "exit"],
        {
            "tokens": {
                "id_token": "fresh-id",
                "access_token": "fresh-access",
                "refresh_token": "rotated-refresh",
                "account_id": "subscription-account",
            },
            "last_refresh": "2026-08-13T12:34:56Z",
            "future_auth_field": {"preserved": True},
        },
    )


def test_codex_store_releases_its_credential_lock_after_reconciliation(
    tmp_path: Path,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    store = CodexFileCredentialStore(source)
    original, replacement = rotation(store)

    reconciled = store.reconcile(original, replacement)

    assert (
        reconciled.tokens.access_token,
        tuple(sorted(path.name for path in tmp_path.iterdir())),
    ) == ("fresh-access", ("auth.json",))


def test_codex_store_retries_a_contested_credential_lock(tmp_path: Path) -> None:
    source = tmp_path / "auth.json"
    document = credential_document("rejected", "refresh")
    source.write_text(json.dumps(document))
    occupied = tmp_path / ".auth-write.lock"
    occupied.mkdir()
    clock = Clock()
    store = CodexFileCredentialStore(
        source,
        lambda directory: CodexCredentialStorageLock(
            directory,
            acquisition_attempts=3,
            retry_seconds=lambda _: 0.1,
            monotonic=clock.monotonic,
            sleep=clock.sleep,
        ),
    )
    original, replacement = rotation(store)

    with pytest.raises(CredentialLockTimeoutError) as raised:
        store.reconcile(original, replacement)

    assert (raised.value, clock, msgspec.json.decode(source.read_bytes())) == (
        CredentialLockTimeoutError(occupied, 0.2),
        Clock(0.2),
        document,
    )


def test_codex_store_publishes_a_rotation_durably(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("rejected", "refresh")))
    store = CodexFileCredentialStore(source)
    original, replacement = rotation(store)
    synchronized: list[str] = []
    original_fsync = os.fsync

    def record_fsync(descriptor: int) -> None:
        mode = os.fstat(descriptor).st_mode
        synchronized.append("directory" if stat.S_ISDIR(mode) else "file")
        original_fsync(descriptor)

    monkeypatch.setattr(codex_runtime.os, "fsync", record_fsync)

    reconciled = store.reconcile(original, replacement)

    assert (reconciled.tokens.access_token, synchronized) == (
        "fresh-access",
        ["file", "directory"],
    )


def test_codex_identity_rejects_a_different_host_account(tmp_path: Path) -> None:
    source = tmp_path / "auth.json"
    source.write_text(json.dumps(credential_document("access", "refresh")))
    broker = identity(
        source,
        httpx.MockTransport(lambda _: httpx.Response(500)),
    )
    source.write_text(
        json.dumps(
            credential_document(
                "other-access",
                "other-refresh",
                account_id="other-account",
            )
        )
    )

    with pytest.raises(CodexSubscriptionAccountChangedError) as raised:
        broker.authentication()

    assert raised.value == CodexSubscriptionAccountChangedError(
        "subscription-account",
        "other-account",
    )
