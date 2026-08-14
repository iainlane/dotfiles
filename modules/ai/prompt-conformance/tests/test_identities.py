import errno
import os
import stat
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

import httpx
import msgspec
import pytest

import claude_prompt_conformance.identities as identities_runtime
from claude_prompt_conformance.codex_identity import (
    CodexCredentialStateDirectoryCreateError,
    CodexCredentialStateDirectoryUnsafeError,
    CodexHostIdentity,
    CodexInstanceCredentialRemoveError,
)
from claude_prompt_conformance.credential_lock import (
    ClaudeCredentialRefreshLock,
    ClaudeCredentialStorageLock,
    CredentialLockReleaseError,
    CredentialLockTimeoutError,
)
from claude_prompt_conformance.credentials import (
    ClaudeCredential,
    ClaudeRefreshTokenMissingError,
    ClaudeTokenMissingError,
)
from claude_prompt_conformance.identities import (
    AnthropicOAuthRefresher,
    ClaudeCredentialFileWriteError,
    ClaudeCredentialRefreshAccessTokenMissingError,
    ClaudeCredentialRefreshClassificationError,
    ClaudeCredentialRefreshDeadlineError,
    ClaudeCredentialRefreshExpiredError,
    ClaudeCredentialRefreshResponseError,
    ClaudeFileCredentialStore,
    ClaudeOAuthIdentity,
)
from claude_prompt_conformance.models import ClaudeBillingMode
from claude_prompt_conformance.protocols.claude import ClaudeOAuth

from .helpers import ExitFailingLock, codex_identity


def credential_store(source: Path) -> ClaudeFileCredentialStore:
    return ClaudeFileCredentialStore(
        source,
        ClaudeCredentialRefreshLock(source.parent),
        ClaudeCredentialStorageLock(source.parent),
    )


def oauth_credentials(
    access_token: str,
    refresh_token: str,
    expires_at: int,
    *,
    client_id: str = "credential-client",
    mcp_token: str = "preserved-mcp-token",
) -> ClaudeCredential:
    return ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": access_token,
                    "refreshToken": refresh_token,
                    "expiresAt": expires_at,
                    "refreshTokenExpiresAt": 9_000_000,
                    "scopes": ["user:profile", "user:inference"],
                    "clientId": client_id,
                    "subscriptionType": "max",
                    "rateLimitTier": "default_claude_max_5x",
                    "futureOauthField": {"preserved": True},
                },
                "mcpOAuth": {"context7": {"accessToken": mcp_token}},
                "futureTopLevelField": {"preserved": True},
            }
        )
    )


@pytest.mark.parametrize(
    ("access_token", "refresh_token", "expected"),
    [
        ("", "refresh", ClaudeTokenMissingError()),
        ("access", "", ClaudeRefreshTokenMissingError()),
    ],
)
def test_claude_credential_rejects_incomplete_oauth_state(
    access_token: str,
    refresh_token: str,
    expected: Exception,
) -> None:
    with pytest.raises(type(expected)) as raised:
        oauth_credentials(access_token, refresh_token, 1)

    assert raised.value == expected


def test_claude_file_identity_retains_the_normal_login_for_the_run(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("oauth-token", "refresh-token", 2_000_000)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "claude-client",
            clock=lambda: 1_000,
            transport=httpx.MockTransport(lambda _: httpx.Response(500)),
        ),
        clock=lambda: 1_000,
    )
    state = tmp_path / "state"

    assert (
        identity.billing_mode,
        identity.environment(state),
        identity.access_token(),
        store.load(),
    ) == (
        ClaudeBillingMode.SUBSCRIPTION,
        {
            "CLAUDE_CONFIG_DIR": str(state / ".claude"),
            "HOME": str(state),
        },
        "oauth-token",
        credential,
    )


def test_claude_identity_refreshes_and_persists_a_rejected_login(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring-token", "refresh-token", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)

    def exchange(request: httpx.Request) -> httpx.Response:
        payload = msgspec.json.decode(request.content)
        if payload != {
            "grant_type": "refresh_token",
            "refresh_token": "refresh-token",
            "client_id": "credential-client",
            "scope": "user:profile user:inference",
        }:
            return httpx.Response(422)

        return httpx.Response(
            200,
            json={
                "access_token": "fresh-token",
                "refresh_token": "rotated-refresh-token",
                "expires_in": 3_600,
                "refresh_token_expires_in": 7_200,
                "scope": "user:inference user:profile",
            },
        )

    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "claude-client",
            clock=lambda: 1_000,
            transport=httpx.MockTransport(exchange),
        ),
        clock=lambda: 1_000,
    )

    expected = credential.with_oauth(
        ClaudeOAuth(
            access_token="fresh-token",
            refresh_token="rotated-refresh-token",
            expires_at=4_600_000,
            refresh_token_expires_at=8_200_000,
            scopes=("user:inference", "user:profile"),
            client_id="credential-client",
            subscription_type="max",
            rate_limit_tier="default_claude_max_5x",
        )
    )

    assert (
        identity.refresh_access_token("expiring-token", float("inf")),
        store.load(),
        msgspec.json.decode(credentials.read_bytes()),
        tuple(sorted(path.name for path in tmp_path.iterdir())),
    ) == (
        "fresh-token",
        expected,
        expected.document,
        ("credentials.json",),
    )


def test_claude_refresh_reports_http_failure_as_a_typed_error() -> None:
    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "claude-client",
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                401,
                json={
                    "error": "invalid_grant",
                    "error_description": "refresh token expired",
                },
            )
        ),
    )

    with pytest.raises(ClaudeCredentialRefreshResponseError) as raised:
        refresher.refresh(oauth_credentials("old", "refresh", 1).oauth, float("inf"))

    assert (raised.value, str(raised.value)) == (
        ClaudeCredentialRefreshResponseError(
            401,
            "invalid_grant",
            "refresh token expired",
        ),
        (
            "Claude's OAuth service returned status 401: "
            "invalid_grant: refresh token expired"
        ),
    )


def test_claude_refresh_adds_current_scopes_for_the_default_client() -> None:
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        return httpx.Response(
            200,
            json={
                "access_token": "fresh",
                "refresh_token": "rotated",
                "expires_in": 60,
            },
        )

    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "default-client",
        clock=lambda: 1_000,
        transport=httpx.MockTransport(exchange),
    )
    original = ClaudeOAuth("old", "refresh", 1, subscription_type="max")

    assert (refresher.refresh(original, float("inf")), requests) == (
        ClaudeOAuth(
            access_token="fresh",
            refresh_token="rotated",
            expires_at=1_060_000,
            scopes=(
                "user:profile",
                "user:inference",
                "user:sessions:claude_code",
                "user:mcp_servers",
                "user:file_upload",
            ),
            subscription_type="max",
        ),
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "default-client",
                "scope": (
                    "user:profile user:inference user:sessions:claude_code "
                    "user:mcp_servers user:file_upload"
                ),
            }
        ],
    )


def test_claude_refresh_retries_stored_scopes_after_invalid_scope() -> None:
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        payload = msgspec.json.decode(request.content)
        requests.append(payload)
        if payload["scope"] != "user:inference":
            return httpx.Response(400, json={"error": "invalid_scope"})
        return httpx.Response(200, json={"access_token": "fresh", "expires_in": 60})

    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "default-client",
        clock=lambda: 1_000,
        transport=httpx.MockTransport(exchange),
    )
    original = ClaudeOAuth(
        "old",
        "refresh",
        1,
        scopes=("user:inference",),
    )

    assert (refresher.refresh(original, float("inf")), requests) == (
        ClaudeOAuth(
            access_token="fresh",
            refresh_token="refresh",
            expires_at=1_060_000,
            scopes=("user:inference",),
        ),
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "default-client",
                "scope": (
                    "user:profile user:inference user:sessions:claude_code "
                    "user:mcp_servers user:file_upload"
                ),
            },
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "default-client",
                "scope": "user:inference",
            },
        ],
    )


@pytest.mark.parametrize(
    "credential",
    (
        ClaudeOAuth("old", "refresh", 1),
        ClaudeOAuth("old", "refresh", 1, scopes=("user:profile",)),
        ClaudeOAuth("old", "refresh", 1, scopes=("unknown",)),
        ClaudeOAuth("old", "refresh", 1, client_id="custom-client"),
        ClaudeOAuth(
            "old",
            "refresh",
            1,
            scopes=("user:profile",),
            client_id="custom-client",
        ),
    ),
)
def test_claude_refresh_rejects_an_unclassified_credential(
    credential: ClaudeOAuth,
) -> None:
    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "default-client",
        transport=httpx.MockTransport(
            lambda _: pytest.fail("an unclassified credential must not be sent")
        ),
    )

    with pytest.raises(ClaudeCredentialRefreshClassificationError) as raised:
        refresher.refresh(credential, float("inf"))

    assert raised.value == ClaudeCredentialRefreshClassificationError()


def test_claude_refresh_does_not_retry_scopes_past_the_callback_deadline() -> None:
    requests: list[dict[str, str]] = []
    observed_times = iter((0.0, 29.0))

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        return httpx.Response(400, json={"error": "invalid_scope"})

    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "default-client",
        monotonic=lambda: next(observed_times),
        transport=httpx.MockTransport(exchange),
    )
    original = ClaudeOAuth(
        "old",
        "refresh",
        1,
        scopes=("user:inference",),
    )

    with pytest.raises(ClaudeCredentialRefreshDeadlineError) as raised:
        refresher.refresh(original, 28)

    assert (raised.value, requests) == (
        ClaudeCredentialRefreshDeadlineError(28, 29),
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "default-client",
                "scope": (
                    "user:profile user:inference user:sessions:claude_code "
                    "user:mcp_servers user:file_upload"
                ),
            }
        ],
    )


def test_claude_refresh_rejects_a_success_without_an_access_token() -> None:
    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "fallback-client",
        transport=httpx.MockTransport(
            lambda _: httpx.Response(200, json={"access_token": "", "expires_in": 60})
        ),
    )

    with pytest.raises(ClaudeCredentialRefreshAccessTokenMissingError):
        refresher.refresh(oauth_credentials("old", "refresh", 1).oauth, float("inf"))


def test_claude_identity_rejects_an_expired_refreshed_token(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "fallback-client",
            clock=lambda: 1_000,
            transport=httpx.MockTransport(
                lambda _: httpx.Response(
                    200,
                    json={"access_token": "expired", "expires_in": 0},
                )
            ),
        ),
        clock=lambda: 1_000,
    )

    with pytest.raises(ClaudeCredentialRefreshExpiredError) as raised:
        identity.refresh_access_token("expiring", float("inf"))

    assert (raised.value, store.load()) == (
        ClaudeCredentialRefreshExpiredError(1_000_000, 1_000_000),
        credential,
    )


def test_claude_identity_preserves_a_concurrently_rotated_host_login(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    concurrent = oauth_credentials(
        "host-fresh",
        "host-rotated-refresh",
        4_600_000,
        mcp_token="host-updated-mcp",
    )
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        return httpx.Response(500)

    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "fallback-client",
            clock=lambda: 1_000,
            transport=httpx.MockTransport(exchange),
        ),
        clock=lambda: 1_000,
    )
    credentials.write_bytes(concurrent.encode())

    assert (
        identity.refresh_access_token("expiring", float("inf")),
        store.load(),
        requests,
        repr(concurrent),
    ) == (
        "host-fresh",
        concurrent,
        [],
        "ClaudeCredential()",
    )


def test_claude_identity_shares_one_coherent_refresh_across_workers(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-token",
                "refresh_token": "rotated-token",
                "expires_in": 3_600,
            },
        )

    refresher = AnthropicOAuthRefresher(
        "https://claude.invalid/oauth/token",
        "fallback-client",
        clock=lambda: 1_000,
        transport=httpx.MockTransport(exchange),
    )
    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        refresher,
        clock=lambda: 1_000,
    )

    with ThreadPoolExecutor(max_workers=4) as executor:
        access_tokens = tuple(
            executor.map(
                lambda _: identity.refresh_access_token("expiring", float("inf")),
                range(4),
            )
        )

    persisted = store.load()
    assert (access_tokens, persisted, requests) == (
        ("fresh-token", "fresh-token", "fresh-token", "fresh-token"),
        credential.with_oauth(
            ClaudeOAuth(
                access_token="fresh-token",
                refresh_token="rotated-token",
                expires_at=4_600_000,
                refresh_token_expires_at=9_000_000,
                scopes=("user:profile", "user:inference"),
                client_id="credential-client",
                subscription_type="max",
                rate_limit_tier="default_claude_max_5x",
            )
        ),
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "credential-client",
                "scope": "user:profile user:inference",
            }
        ],
    )


def test_claude_identity_serves_a_rotated_token_to_a_late_caller(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-token",
                "refresh_token": "rotated-token",
                "expires_in": 3_600,
            },
        )

    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "fallback-client",
            clock=lambda: 1_000,
            monotonic=lambda: 5_000.0,
            transport=httpx.MockTransport(exchange),
        ),
        clock=lambda: 1_000,
        monotonic=lambda: 5_000.0,
    )

    winner = identity.refresh_access_token("expiring", 6_000.0)
    queued = identity.refresh_access_token("expiring", 4_000.0)

    assert (winner, queued, requests) == (
        "fresh-token",
        "fresh-token",
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "credential-client",
                "scope": "user:profile user:inference",
            }
        ],
    )


def test_claude_identity_keeps_a_rotation_persisted_past_the_deadline(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    store = credential_store(credentials)
    elapsed = 0.0

    def monotonic() -> float:
        return elapsed

    def exchange(_: httpx.Request) -> httpx.Response:
        nonlocal elapsed
        elapsed = 20.0
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-token",
                "refresh_token": "rotated-token",
                "expires_in": 3_600,
            },
        )

    identity = ClaudeOAuthIdentity(
        store.load(),
        store,
        AnthropicOAuthRefresher(
            "https://claude.invalid/oauth/token",
            "fallback-client",
            clock=lambda: 1_000,
            monotonic=monotonic,
            transport=httpx.MockTransport(exchange),
        ),
        clock=lambda: 1_000,
        monotonic=monotonic,
    )

    access_token = identity.refresh_access_token("expiring", 10.0)

    assert (access_token, elapsed, store.load().oauth.access_token) == (
        "fresh-token",
        20.0,
        "fresh-token",
    )


def test_claude_identities_coordinate_refresh_across_process_owners(
    tmp_path: Path,
) -> None:
    credential = oauth_credentials("expiring", "refresh", 1)
    credentials = tmp_path / "credentials.json"
    credentials.write_bytes(credential.encode())
    refresh_started = Event()
    complete_refresh = Event()
    requests: list[dict[str, str]] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(msgspec.json.decode(request.content))
        refresh_started.set()
        complete_refresh.wait()
        return httpx.Response(
            200,
            json={
                "access_token": "shared-fresh-token",
                "refresh_token": "shared-rotated-token",
                "expires_in": 3_600,
            },
        )

    def identity() -> ClaudeOAuthIdentity:
        store = credential_store(credentials)
        return ClaudeOAuthIdentity(
            store.load(),
            store,
            AnthropicOAuthRefresher(
                "https://claude.invalid/oauth/token",
                "fallback-client",
                clock=lambda: 1_000,
                transport=httpx.MockTransport(exchange),
            ),
            clock=lambda: 1_000,
        )

    first = identity()
    second = identity()
    with ThreadPoolExecutor(max_workers=2) as executor:
        first_result = executor.submit(
            first.refresh_access_token,
            "expiring",
            float("inf"),
        )
        refresh_started.wait()
        second_result = executor.submit(
            second.refresh_access_token,
            "expiring",
            float("inf"),
        )
        complete_refresh.set()
        access_tokens = (
            first_result.result(),
            second_result.result(),
        )

    expected = credential.with_oauth(
        ClaudeOAuth(
            access_token="shared-fresh-token",
            refresh_token="shared-rotated-token",
            expires_at=4_600_000,
            refresh_token_expires_at=9_000_000,
            scopes=("user:profile", "user:inference"),
            client_id="credential-client",
            subscription_type="max",
            rate_limit_tier="default_claude_max_5x",
        )
    )
    assert (access_tokens, credential_store(credentials).load(), requests) == (
        ("shared-fresh-token", "shared-fresh-token"),
        expected,
        [
            {
                "grant_type": "refresh_token",
                "refresh_token": "refresh",
                "client_id": "credential-client",
                "scope": "user:profile user:inference",
            }
        ],
    )


def test_claude_file_store_reconciles_a_rotated_token_after_lock_loss(
    tmp_path: Path,
) -> None:
    credentials = tmp_path / "credentials.json"
    original = oauth_credentials("expiring", "refresh", 1)
    replacement = oauth_credentials("fresh", "rotated", 2_000)
    concurrent = ClaudeCredential.decode(
        msgspec.json.encode(
            original.document | {"mcpOAuth": {"server": {"token": "new"}}}
        )
    )
    credentials.write_bytes(original.encode())
    current_lock = tmp_path / ".oauth_refresh.lock"
    displaced_lock = tmp_path / "displaced.lock"
    store = ClaudeFileCredentialStore(
        credentials,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )

    def lose_lock(_: ClaudeCredential) -> ClaudeCredential:
        credentials.write_bytes(concurrent.encode())
        current_lock.rename(displaced_lock)
        return replacement

    result = store.mutate(lose_lock)
    expected = concurrent.with_oauth(replacement.oauth)

    assert (
        result,
        credential_store(credentials).load(),
        tuple(sorted(path.name for path in tmp_path.iterdir())),
    ) == (
        expected,
        expected,
        ("credentials.json", "displaced.lock"),
    )


def test_claude_file_store_applies_one_storage_lock_retry_sequence(
    tmp_path: Path,
) -> None:
    credentials = tmp_path / "credentials.json"
    original = oauth_credentials("expiring", "refresh", 1)
    replacement = oauth_credentials("fresh", "rotated", 2_000)
    credentials.write_bytes(original.encode())
    occupied = tmp_path / ".storage-write.lock"
    occupied.mkdir()
    elapsed = 0.0

    def monotonic() -> float:
        return elapsed

    def advance(seconds: float) -> None:
        nonlocal elapsed
        elapsed += seconds

    store = ClaudeFileCredentialStore(
        credentials,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(
            tmp_path,
            acquisition_attempts=2,
            retry_seconds=lambda _: 0.1,
            monotonic=monotonic,
            sleep=advance,
        ),
    )

    with pytest.raises(CredentialLockTimeoutError) as raised:
        store.mutate(lambda _: replacement)

    assert (raised.value, elapsed, credential_store(credentials).load()) == (
        CredentialLockTimeoutError(occupied, 0.1),
        0.1,
        original,
    )


@pytest.mark.parametrize("failure_at", ("refresh", "storage"))
def test_claude_file_store_preserves_a_result_after_lock_cleanup_failure(
    tmp_path: Path,
    failure_at: str,
) -> None:
    credentials = tmp_path / "credentials.json"
    original = oauth_credentials("expiring", "refresh", 1)
    replacement = oauth_credentials("fresh", "rotated", 2_000)
    credentials.write_bytes(original.encode())
    failure = ExitFailingLock(
        CredentialLockReleaseError(
            tmp_path / f"{failure_at}.lock",
            OSError(errno.EIO, "fixture release failure"),
        )
    )
    refresh_lock = (
        failure if failure_at == "refresh" else ClaudeCredentialRefreshLock(tmp_path)
    )
    storage_lock = (
        failure if failure_at == "storage" else ClaudeCredentialStorageLock(tmp_path)
    )
    store = ClaudeFileCredentialStore(credentials, refresh_lock, storage_lock)

    result = store.mutate(lambda _: replacement)

    assert (result, credential_store(credentials).load()) == (
        replacement,
        replacement,
    )


def test_claude_file_store_publishes_a_rotation_durably(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    credentials = tmp_path / "credentials.json"
    original = oauth_credentials("expiring", "refresh", 1)
    replacement = oauth_credentials("fresh", "rotated", 2_000)
    credentials.write_bytes(original.encode())
    store = credential_store(credentials)
    synchronized: list[str] = []
    original_fsync = os.fsync

    def record_fsync(descriptor: int) -> None:
        mode = os.fstat(descriptor).st_mode
        synchronized.append("directory" if stat.S_ISDIR(mode) else "file")
        original_fsync(descriptor)

    monkeypatch.setattr(identities_runtime.os, "fsync", record_fsync)

    result = store.mutate(lambda _: replacement)

    assert (result, synchronized, credential_store(credentials).load()) == (
        replacement,
        ["file", "directory"],
        replacement,
    )


def test_claude_file_store_reports_atomic_write_failure(tmp_path: Path) -> None:
    destination = tmp_path / "missing" / "credentials.json"
    expected = oauth_credentials("access", "refresh", 1)
    replacement = oauth_credentials("updated-access", "updated-refresh", 2)
    destination.parent.mkdir()
    destination.write_bytes(expected.encode())
    store = ClaudeFileCredentialStore(
        destination,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )

    destination.parent.chmod(0o500)
    try:
        with pytest.raises(ClaudeCredentialFileWriteError) as raised:
            store.mutate(lambda _: replacement)
    finally:
        destination.parent.chmod(0o700)

    assert (raised.value.destination, raised.value.cause.errno) == (
        destination,
        errno.EACCES,
    )


def test_codex_identity_resolves_the_normal_client_home(tmp_path: Path) -> None:
    home = tmp_path / "home"
    configured_home = tmp_path / "configured-codex"
    configured = codex_identity(configured_home)
    default = codex_identity(home / ".codex")

    identities = [
        CodexHostIdentity.from_environment(
            environment,
            home,
            "https://codex.invalid/oauth/token",
            "codex-client",
        )
        for environment in (
            {"CODEX_HOME": str(configured_home)},
            {},
        )
    ]

    assert [
        (identity.store.source, identity.credential) for identity in identities
    ] == [
        (configured.store.source, configured.credential),
        (default.store.source, default.credential),
    ]


def test_codex_identity_canonicalizes_a_relative_configured_home(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    configured_home = tmp_path / "configured-codex"
    expected = codex_identity(configured_home)
    monkeypatch.chdir(tmp_path)

    identity = CodexHostIdentity.from_environment(
        {"CODEX_HOME": configured_home.name},
        tmp_path / "home",
        "https://codex.invalid/oauth/token",
        "codex-client",
    )

    assert (identity.store.source, identity.credential) == (
        expected.store.source,
        expected.credential,
    )


def test_codex_identity_keeps_instance_state_free_of_credentials(
    tmp_path: Path,
) -> None:
    codex_home = tmp_path / "host-codex"
    identity = codex_identity(codex_home)
    host_document = (codex_home / "auth.json").read_bytes()
    state = tmp_path / "state"
    state.mkdir()
    (state / ".codex").mkdir()
    (state / ".codex" / "auth.json").write_text("legacy refresh token")

    assert (
        identity.environment(state),
        identity.environment(state),
        tuple((state / ".codex").iterdir()),
        identity.authentication(),
        identity.secrets(),
    ) == (
        {"CODEX_HOME": str(state / ".codex"), "HOME": str(state)},
        {"CODEX_HOME": str(state / ".codex"), "HOME": str(state)},
        (),
        identity.credential.access(),
        (),
    )
    assert (codex_home / "auth.json").read_bytes() == host_document


def test_codex_identity_reports_state_directory_creation_failure(
    tmp_path: Path,
) -> None:
    state = tmp_path / "state"
    state.mkdir()
    state.chmod(0o500)
    identity = codex_identity(tmp_path / "host-codex")
    expected = CodexCredentialStateDirectoryCreateError(
        state / ".codex",
        OSError(errno.EACCES, "Permission denied"),
    )

    try:
        with pytest.raises(CodexCredentialStateDirectoryCreateError) as raised:
            identity.environment(state)
    finally:
        state.chmod(0o700)

    assert (
        raised.value.directory,
        raised.value.cause.errno,
        tuple(state.iterdir()),
    ) == (
        expected.directory,
        expected.cause.errno,
        (),
    )


def test_codex_identity_reports_legacy_credential_removal_failure(
    tmp_path: Path,
) -> None:
    state = tmp_path / "state"
    instance_home = state / ".codex"
    instance_home.mkdir(parents=True)
    legacy_credential = instance_home / "auth.json"
    legacy_credential.write_text("legacy refresh token")
    instance_home.chmod(0o500)
    identity = codex_identity(tmp_path / "host-codex")

    try:
        with pytest.raises(CodexInstanceCredentialRemoveError) as raised:
            identity.environment(state)
    finally:
        instance_home.chmod(0o700)

    assert (
        raised.value.source,
        raised.value.cause.errno,
        legacy_credential.read_text(),
    ) == (
        legacy_credential,
        errno.EACCES,
        "legacy refresh token",
    )


def test_codex_identity_does_not_follow_an_instance_home_symlink(
    tmp_path: Path,
) -> None:
    codex_home = tmp_path / "host-codex"
    identity = codex_identity(codex_home)
    external = tmp_path / "external"
    external.mkdir()
    (external / "sentinel").write_text("unchanged\n")
    state = tmp_path / "state"
    state.mkdir()
    (state / ".codex").symlink_to(external, target_is_directory=True)
    with pytest.raises(CodexCredentialStateDirectoryUnsafeError) as raised:
        identity.environment(state)

    assert (
        raised.value,
        (state / ".codex").readlink(),
        tuple(
            (path.name, path.read_bytes())
            for path in sorted(external.iterdir())
            if path.is_file()
        ),
    ) == (
        CodexCredentialStateDirectoryUnsafeError(state / ".codex"),
        external,
        (("sentinel", b"unchanged\n"),),
    )
