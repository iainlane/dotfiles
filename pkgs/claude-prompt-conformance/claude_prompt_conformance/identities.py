"""Claude identity capabilities backed by the host's own login."""

import asyncio
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from threading import Lock

import httpx
import msgspec

from .credential_lock import (
    CredentialLockCompromisedError,
    CredentialLockReleaseError,
    CredentialLockTimeoutError,
    CredentialLockUpdateError,
)
from .credentials import ClaudeCredential, validate_oauth
from .errors import ConformanceError
from .models import ClaudeBillingMode
from .ports import (
    ClaudeCredentialRefresher,
    ClaudeCredentialStore,
    CredentialLock,
    ReconcilableCredentials,
)
from .protocols.claude import (
    ClaudeOAuth,
    ClaudeOAuthErrorResponse,
    ClaudeOAuthRefreshResponse,
)
from .storage import replace_private_file


@dataclass(eq=True)
class ClaudeCredentialReconciliationResultMissingError(ConformanceError):
    def __str__(self) -> str:
        return "Claude credential reconciliation produced no result"


@dataclass(eq=True)
class ClaudeCredentialFileReadError(ConformanceError):
    source: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not read the Claude credential at {self.source}: {self.cause}"


@dataclass(eq=True)
class ClaudeCredentialFileWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not update the Claude credential at {self.destination}: {self.cause}"


@dataclass(eq=True)
class ClaudeCredentialRefreshTransportError(ConformanceError):
    cause: Exception

    def __str__(self) -> str:
        return f"could not reach Claude's OAuth service: {self.cause}"


@dataclass(eq=True)
class ClaudeCredentialRefreshResponseError(ConformanceError):
    status_code: int
    error: str | None
    description: str | None

    def __str__(self) -> str:
        detail = self.error or "unknown OAuth error"
        if self.description is not None:
            detail = f"{detail}: {self.description}"

        return f"Claude's OAuth service returned status {self.status_code}: {detail}"


@dataclass(eq=True)
class ClaudeCredentialRefreshFormatError(ConformanceError):
    cause: Exception

    def __str__(self) -> str:
        return f"Claude's OAuth service returned an invalid credential: {self.cause}"


@dataclass(eq=True)
class ClaudeCredentialRefreshAccessTokenMissingError(ConformanceError):
    def __str__(self) -> str:
        return "Claude's OAuth service returned no access token"


@dataclass(eq=True)
class ClaudeCredentialRefreshExpiredError(ConformanceError):
    expires_at: int
    refreshed_at: int

    def __str__(self) -> str:
        return "Claude's OAuth service returned an expired access token"


@dataclass(eq=True)
class ClaudeCredentialRefreshDeadlineError(ConformanceError):
    deadline: float
    observed_at: float

    def __str__(self) -> str:
        return "Claude's OAuth refresh exceeded the SDK callback deadline"


@dataclass(eq=True)
class ClaudeCredentialRefreshClassificationError(ConformanceError):
    def __str__(self) -> str:
        return "Claude's OAuth credential has no client, scopes, or subscription"


_OAUTH_REFRESH_TIMEOUT_SECONDS = 20
_DEFAULT_FIRST_PARTY_SCOPES = (
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload",
)


@dataclass(frozen=True)
class ReconciledCredentialUpdate:
    """Finish one credential update even when a lock is lost part-way.

    A refresh spends the refresh token that it sent, so a completed rotation
    must not be discarded because a lock expired: the replaced token is already
    spent. The update is reconciled against whatever is stored at that moment.
    A refresh token that has changed means the pinned client rotated
    concurrently, and that credential wins; otherwise the replacement's OAuth
    fields are merged into the stored credential and written back only when
    they differ.
    """

    credentials: ReconcilableCredentials
    lock: CredentialLock
    storage_lock: CredentialLock

    def apply(
        self,
        transform: Callable[[ClaudeCredential], ClaudeCredential],
    ) -> ClaudeCredential:
        original: ClaudeCredential | None = None
        replacement: ClaudeCredential | None = None
        reconciliation_started = False
        reconciled: ClaudeCredential | None = None
        try:
            with self.lock:
                original = self.credentials.current()
                replacement = transform(original)
                self.lock.check()
                reconciliation_started = True
                reconciled = self._reconcile(original, replacement)
        except (
            CredentialLockCompromisedError,
            CredentialLockReleaseError,
            CredentialLockTimeoutError,
            CredentialLockUpdateError,
        ):
            if reconciled is not None:
                return reconciled
            if reconciliation_started:
                raise
            if original is None or replacement is None:
                raise

        if reconciled is not None:
            return reconciled
        return self._reconcile(original, replacement)

    def _reconcile(
        self,
        original: ClaudeCredential,
        replacement: ClaudeCredential,
    ) -> ClaudeCredential:
        result: ClaudeCredential | None = None
        try:
            with self.storage_lock:
                current = self.credentials.current()
                if current.oauth.refresh_token != original.oauth.refresh_token:
                    result = current
                else:
                    reconciled = current.with_oauth(replacement.oauth)
                    if reconciled == current:
                        result = current
                    else:
                        self.storage_lock.check()
                        result = self.credentials.replace(reconciled)
        except (
            CredentialLockCompromisedError,
            CredentialLockReleaseError,
            CredentialLockUpdateError,
        ):
            if result is None:
                raise

        if result is None:
            raise ClaudeCredentialReconciliationResultMissingError
        return result


@dataclass(frozen=True)
class ClaudeFileCredentialStore:
    """Load and atomically update Claude's normal credentials file."""

    source: Path
    lock: CredentialLock
    storage_lock: CredentialLock

    def load(self) -> ClaudeCredential:
        try:
            value = self.source.read_bytes()
        except OSError as error:
            raise ClaudeCredentialFileReadError(self.source, error) from error

        return ClaudeCredential.decode(value)

    def current(self) -> ClaudeCredential:
        """Read the credential the host has stored now."""

        return self.load()

    def replace(self, credential: ClaudeCredential) -> ClaudeCredential:
        """Publish one credential where the pinned client will find it."""

        self._write(credential)
        return credential

    def mutate(
        self,
        transform: Callable[[ClaudeCredential], ClaudeCredential],
    ) -> ClaudeCredential:
        return ReconciledCredentialUpdate(
            self,
            self.lock,
            self.storage_lock,
        ).apply(transform)

    def _write(self, credential: ClaudeCredential) -> None:
        try:
            replace_private_file(self.source, credential.encode())
        except OSError as error:
            raise ClaudeCredentialFileWriteError(self.source, error) from error


@dataclass(frozen=True)
class AnthropicOAuthRefresher:
    """Refresh Claude credentials using the pinned client's OAuth contract."""

    token_url: str
    client_id: str
    clock: Callable[[], float] = field(default=time.time, repr=False)
    monotonic: Callable[[], float] = field(default=time.monotonic, repr=False)
    transport: httpx.AsyncBaseTransport | None = field(default=None, repr=False)

    def refresh(self, credential: ClaudeOAuth, deadline: float) -> ClaudeOAuth:
        """Exchange the refresh token for a new access token.

        A credential with no client id was issued to the first-party default
        client, so the request asks for that client's usual scopes as well as
        the stored ones. The widening is a guess: a service that answers
        `invalid_scope` is asked again with the credential's own scopes.
        """

        if (
            "user:inference" not in credential.scopes
            and credential.subscription_type is None
        ):
            raise ClaudeCredentialRefreshClassificationError

        default_client = not credential.client_id
        requested_scopes = credential.scopes
        if default_client:
            requested_scopes = tuple(
                dict.fromkeys((*_DEFAULT_FIRST_PARTY_SCOPES, *credential.scopes))
            )

        response = self._post(credential, requested_scopes, deadline)
        failure = self._failure(response)
        if (
            failure is not None
            and failure.error == "invalid_scope"
            and default_client
            and credential.scopes
            and requested_scopes != credential.scopes
        ):
            requested_scopes = credential.scopes
            response = self._post(credential, requested_scopes, deadline)
            failure = self._failure(response)
        if failure is not None:
            raise ClaudeCredentialRefreshResponseError(
                response.status_code,
                failure.error,
                failure.error_description,
            )

        return self._decode_success(credential, requested_scopes, response)

    def _post(
        self,
        credential: ClaudeOAuth,
        scopes: tuple[str, ...],
        deadline: float,
    ) -> httpx.Response:
        payload = {
            "grant_type": "refresh_token",
            "refresh_token": credential.refresh_token,
            "client_id": credential.client_id or self.client_id,
            "scope": " ".join(scopes),
        }
        observed_at = self.monotonic()
        remaining = deadline - observed_at
        if remaining <= 0:
            raise ClaudeCredentialRefreshDeadlineError(deadline, observed_at)
        try:
            response = asyncio.run(self._post_before(payload, remaining))
        except TimeoutError as error:
            raise ClaudeCredentialRefreshDeadlineError(
                deadline,
                self.monotonic(),
            ) from error
        except httpx.RequestError as error:
            raise ClaudeCredentialRefreshTransportError(error) from error

        return response

    async def _post_before(
        self,
        payload: dict[str, str],
        remaining: float,
    ) -> httpx.Response:
        # httpx applies its timeout to each socket phase, so the caller's
        # deadline needs a timeout around the whole exchange.
        async with asyncio.timeout(remaining):
            async with httpx.AsyncClient(
                transport=self.transport,
                timeout=min(_OAUTH_REFRESH_TIMEOUT_SECONDS, remaining),
            ) as client:
                return await client.post(self.token_url, json=payload)

    @staticmethod
    def _failure(response: httpx.Response) -> ClaudeOAuthErrorResponse | None:
        if response.is_success:
            return None
        try:
            return msgspec.json.decode(
                response.content,
                type=ClaudeOAuthErrorResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError):
            return ClaudeOAuthErrorResponse()

    def _decode_success(
        self,
        credential: ClaudeOAuth,
        requested_scopes: tuple[str, ...],
        response: httpx.Response,
    ) -> ClaudeOAuth:
        try:
            refreshed = msgspec.json.decode(
                response.content,
                type=ClaudeOAuthRefreshResponse,
            )
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise ClaudeCredentialRefreshFormatError(error) from error
        if not refreshed.access_token:
            raise ClaudeCredentialRefreshAccessTokenMissingError

        # Claude's credential stores its expiry as milliseconds since the
        # epoch, and the OAuth response gives a lifetime in seconds.
        now = round(self.clock() * 1_000)
        refresh_token_expiry = credential.refresh_token_expires_at
        if refreshed.refresh_token_expires_in is not None:
            refresh_token_expiry = now + refreshed.refresh_token_expires_in * 1_000
        scopes = requested_scopes
        if refreshed.scope is not None:
            scopes = tuple(refreshed.scope.split())
        return ClaudeOAuth(
            access_token=refreshed.access_token,
            refresh_token=refreshed.refresh_token or credential.refresh_token,
            expires_at=now + refreshed.expires_in * 1_000,
            refresh_token_expires_at=refresh_token_expiry,
            scopes=scopes,
            client_id=credential.client_id,
            subscription_type=credential.subscription_type,
            rate_limit_tier=credential.rate_limit_tier,
        )


class ClaudeOAuthIdentity:
    """One renewable Claude login, shared by every candidate process in a run."""

    def __init__(
        self,
        credential: ClaudeCredential,
        store: ClaudeCredentialStore,
        refresher: ClaudeCredentialRefresher,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        validate_oauth(credential.oauth)
        self._credential = credential
        self._store = store
        self._refresher = refresher
        self._clock = clock
        self._monotonic = monotonic
        self._lock = Lock()

    @property
    def billing_mode(self) -> ClaudeBillingMode:
        """Identify OAuth authentication as subscription-backed usage."""

        return ClaudeBillingMode.SUBSCRIPTION

    def environment(self, state: Path) -> dict[str, str]:
        return {
            "CLAUDE_CONFIG_DIR": str(state / ".claude"),
            "HOME": str(state),
        }

    def access_token(self) -> str:
        with self._lock:
            return self._credential.oauth.access_token

    def refresh_access_token(self, rejected: str, deadline: float) -> str:
        """Replace a token that Claude rejected and return the token now in use."""

        with self._lock:
            # A caller queued behind a winning refresh arrives with a token
            # that the winner has already replaced, so take the new one before
            # looking at the clock.
            oauth = self._credential.oauth
            if oauth.access_token != rejected:
                return oauth.access_token

            observed_at = self._monotonic()
            if observed_at >= deadline:
                raise ClaudeCredentialRefreshDeadlineError(deadline, observed_at)

            # Keep a rotation that reached durable storage even when it
            # finished after the deadline: the refresh token it spent cannot be
            # used again, so discarding the result would strand the credential.
            self._credential = self._store.mutate(
                lambda current: self._refresh_rejected(current, rejected, deadline),
            )
            return self._credential.oauth.access_token

    def _refresh_rejected(
        self,
        current: ClaudeCredential,
        rejected: str,
        deadline: float,
    ) -> ClaudeCredential:
        oauth = current.oauth
        validate_oauth(oauth)
        if oauth.access_token != rejected:
            return current

        refreshed = self._refresher.refresh(oauth, deadline)
        validate_oauth(refreshed)
        refreshed_at = round(self._clock() * 1_000)
        if refreshed.expires_at <= refreshed_at:
            raise ClaudeCredentialRefreshExpiredError(
                refreshed.expires_at,
                refreshed_at,
            )

        return current.with_oauth(refreshed)
