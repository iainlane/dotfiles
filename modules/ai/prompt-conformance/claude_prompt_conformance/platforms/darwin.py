"""macOS process isolation implemented with Seatbelt."""

import json
import os
import pwd
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path

from ..claude_storage import ClaudeSecureStorage
from ..credentials import ClaudeCredential
from ..errors import ConformanceError
from ..identities import ReconciledCredentialUpdate
from ..models import (
    ClaudeKeychainNamespace,
    KeychainItem,
    KeychainRevision,
    NetworkAccess,
    ProcessInvocation,
    ProcessResult,
)
from ..ports import CredentialLock, IsolatedChildProcesses, Keychain, ProcessSession


@dataclass(eq=True)
class IsolationProfileDirectoryCreateError(ConformanceError):
    directory: Path
    cause: OSError

    def __str__(self) -> str:
        return (
            f"could not create isolation profile directory {self.directory}: "
            f"{self.cause}"
        )


@dataclass(eq=True)
class IsolationProfileWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"could not write isolation profile {self.destination}: {self.cause}"


@dataclass(eq=True)
class KeychainReadError(ConformanceError):
    status: int

    def __str__(self) -> str:
        return f"the Keychain returned status {self.status}"


@dataclass(eq=True)
class KeychainWriteError(ConformanceError):
    status: int

    def __str__(self) -> str:
        return f"the Keychain update returned status {self.status}"


@dataclass(eq=True)
class KeychainAuthenticationContextUnavailableError(ConformanceError):
    def __str__(self) -> str:
        return "the macOS Keychain authentication context is unavailable"


@dataclass(eq=True)
class KeychainDataMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the Keychain item contains no data"


@dataclass(eq=True)
class KeychainRevisionMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the Keychain item contains no modification revision"


@dataclass(eq=True)
class KeychainPersistentReferenceMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the Keychain item contains no persistent reference"


@dataclass(eq=True)
class KeychainCredentialNotLoadedError(ConformanceError):
    def __str__(self) -> str:
        return "the Claude Keychain credential has not been loaded"


SYSTEM_READ_PATHS = (
    "/Library",
    "/System",
    "/bin",
    "/dev",
    "/nix/store",
    "/private/etc",
    "/private/var/db/timezone",
    "/private/var/select",
    "/usr",
)
# Host name resolution goes through this socket, not through a capability the
# caller declares, so PUBLIC network access keeps it reachable the same way
# it keeps SYSTEM_READ_PATHS readable.
_SYSTEM_UNIX_SOCKETS = ("/private/var/run/mDNSResponder",)
_KEYCHAIN_ACCOUNT = re.compile(r"^[a-zA-Z0-9._-]+$")
_KEYCHAIN_FALLBACK_ACCOUNT = "claude-code-user"
_LOCAL_AUTHENTICATION_FRAMEWORK = (
    "/System/Library/Frameworks/LocalAuthentication.framework"
)


def claude_keychain_namespace(
    environment: Mapping[str, str],
    storage: ClaudeSecureStorage,
) -> ClaudeKeychainNamespace:
    """Derive the account and service selected by the pinned Claude client."""

    account = environment.get("USER") or _system_username()
    if _KEYCHAIN_ACCOUNT.fullmatch(account) is None:
        account = _KEYCHAIN_FALLBACK_ACCOUNT

    return ClaudeKeychainNamespace(
        account,
        storage.keychain_service,
    )


def _system_username() -> str:
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError):
        return _KEYCHAIN_FALLBACK_ACCOUNT


class DarwinProcessRunner:
    """Map process capabilities to a Seatbelt profile and execute it."""

    def __init__(self, sandbox_program: str, processes: IsolatedChildProcesses) -> None:
        self._sandbox_program = sandbox_program
        self._processes = processes

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        return self._run(invocation, None)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        """Run a bidirectional protocol through the same Seatbelt profile."""

        return self._run(invocation, session)

    def _run(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession | None,
    ) -> ProcessResult:
        profile = invocation.stdout.with_suffix(".sb")
        try:
            profile.parent.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise IsolationProfileDirectoryCreateError(profile.parent, error) from error
        try:
            profile.write_text(seatbelt_profile(invocation))
        except OSError as error:
            raise IsolationProfileWriteError(profile, error) from error
        command = (
            self._sandbox_program,
            "-f",
            str(profile),
            *invocation.command,
        )
        if session is None:
            return self._processes.run(invocation, command)
        return self._processes.run_interactive(invocation, command, session)


class DarwinClaudeCredentialStore:
    """Load and persist Claude's normal macOS Keychain credential."""

    def __init__(
        self,
        username: str,
        service: str,
        keychain: Keychain,
        lock: CredentialLock,
        storage_lock: CredentialLock,
    ) -> None:
        self._username = username
        self._service = service
        self._keychain = keychain
        self._lock = lock
        self._storage_lock = storage_lock
        self._revision: KeychainRevision | None = None
        self._persistent_reference: bytes | None = None
        self._credential: ClaudeCredential | None = None

    def load(self) -> ClaudeCredential:
        item = self._keychain.generic_password(self._username, self._service)
        self._revision = item.revision
        self._persistent_reference = item.persistent_reference
        self._credential = ClaudeCredential.decode(item.value)
        return self._credential

    def mutate(
        self,
        transform: Callable[[ClaudeCredential], ClaudeCredential],
    ) -> ClaudeCredential:
        if self._credential is None:
            raise KeychainCredentialNotLoadedError

        return ReconciledCredentialUpdate(
            self,
            self._lock,
            self._storage_lock,
        ).apply(transform)

    def current(self) -> ClaudeCredential:
        """Reuse the retained secret while the item's revision still matches."""

        if self._revision is None:
            return self.load()
        if self._persistent_reference is None:
            raise KeychainPersistentReferenceMissingError
        revision = self._keychain.generic_password_revision(self._persistent_reference)
        if revision != self._revision:
            return self.load()
        if self._credential is None:
            raise KeychainRevisionMissingError
        return self._credential

    def replace(self, credential: ClaudeCredential) -> ClaudeCredential:
        """Publish one credential into the item the pinned client reads."""

        if self._revision is None:
            raise KeychainRevisionMissingError
        if self._persistent_reference is None:
            raise KeychainPersistentReferenceMissingError
        self._keychain.update_generic_password(
            self._persistent_reference,
            credential.encode(),
        )
        self._revision = None
        self._credential = credential
        return credential


class PyObjCKeychain:
    """Read generic passwords through the macOS Security framework binding."""

    def __init__(self) -> None:
        import Foundation

        # Keychain creates and discards an authentication context for each
        # operation unless the caller supplies one. Retaining the context for
        # the run lets one successful authentication authorize later reads and
        # writes of the same credential.
        framework = Foundation.NSBundle.bundleWithPath_(_LOCAL_AUTHENTICATION_FRAMEWORK)
        if framework is None or not framework.load():
            raise KeychainAuthenticationContextUnavailableError

        authentication = Foundation.NSClassFromString("LAContext")
        if authentication is None:
            raise KeychainAuthenticationContextUnavailableError

        self._authentication = authentication.alloc().init()

    def generic_password(self, account: str, service: str) -> KeychainItem:
        import Security

        query = {
            Security.kSecClass: Security.kSecClassGenericPassword,
            Security.kSecAttrAccount: account,
            Security.kSecAttrService: service,
            Security.kSecReturnData: True,
            Security.kSecReturnAttributes: True,
            Security.kSecReturnPersistentRef: True,
            Security.kSecMatchLimit: Security.kSecMatchLimitOne,
            Security.kSecUseAuthenticationContext: self._authentication,
        }
        status, item = Security.SecItemCopyMatching(query, None)
        if status != Security.errSecSuccess:
            raise KeychainReadError(status)
        if item is None or Security.kSecValueData not in item:
            raise KeychainDataMissingError
        if Security.kSecAttrModificationDate not in item:
            raise KeychainRevisionMissingError
        if Security.kSecValuePersistentRef not in item:
            raise KeychainPersistentReferenceMissingError

        revision = KeychainRevision(
            float(item[Security.kSecAttrModificationDate].timeIntervalSince1970())
        )
        return KeychainItem(
            bytes(item[Security.kSecValueData]),
            revision,
            bytes(item[Security.kSecValuePersistentRef]),
        )

    def update_generic_password(
        self,
        persistent_reference: bytes,
        value: bytes,
    ) -> None:
        import Security

        query = {
            Security.kSecMatchItemList: [persistent_reference],
            Security.kSecUseAuthenticationContext: self._authentication,
        }
        status = Security.SecItemUpdate(
            query,
            {Security.kSecValueData: value},
        )
        if status != Security.errSecSuccess:
            raise KeychainWriteError(status)

    def generic_password_revision(
        self,
        persistent_reference: bytes,
    ) -> KeychainRevision:
        """Read the non-secret revision without requesting password data."""

        import Security

        query = {
            Security.kSecMatchItemList: [persistent_reference],
            Security.kSecReturnAttributes: True,
            Security.kSecMatchLimit: Security.kSecMatchLimitOne,
            Security.kSecUseAuthenticationContext: self._authentication,
        }
        status, item = Security.SecItemCopyMatching(query, None)
        if status != Security.errSecSuccess:
            raise KeychainReadError(status)
        if item is None or Security.kSecAttrModificationDate not in item:
            raise KeychainRevisionMissingError

        return KeychainRevision(
            float(item[Security.kSecAttrModificationDate].timeIntervalSince1970())
        )


def seatbelt_profile(invocation: ProcessInvocation) -> str:
    rules = [
        "(version 1)",
        "(allow default)",
        # SBPL is last-match-wins, so every rule below must come after this
        # import: system.sb is Apple's auto-generated baseline, and importing
        # it first lets our own denies (credentials, hidden paths, network)
        # override whatever it grants rather than the reverse.
        '(import "system.sb")',
        '(deny process-exec (literal "/usr/bin/security"))',
        (
            '(deny mach-lookup (global-name "com.apple.SecurityServer") '
            '(global-name-prefix "com.apple.securityd"))'
        ),
        "(deny file-read*)",
        "(deny file-write*)",
        "(allow file-read-metadata)",
        '(allow file-write* (literal "/dev/null"))',
    ]
    rules.extend(
        f"(allow file-read* (subpath {json.dumps(path)}))" for path in SYSTEM_READ_PATHS
    )
    readable_paths = (
        invocation.capabilities.readable_paths + invocation.capabilities.writable_paths
    )
    rules.extend(
        f"(allow file-read* (subpath {json.dumps(str(path.resolve()))}))"
        for path in readable_paths
    )
    rules.extend(
        f"(allow file-read* (literal {json.dumps(str(path.resolve()))}))"
        for path in (
            invocation.capabilities.writable_files
            + invocation.capabilities.unix_sockets
        )
    )
    rules.extend(
        f"(allow file-write* (subpath {json.dumps(str(path.resolve()))}))"
        for path in invocation.capabilities.writable_paths
    )
    rules.extend(
        f"(allow file-write* (literal {json.dumps(str(path.resolve()))}))"
        for path in invocation.capabilities.writable_files
    )
    # Hidden paths must be denied after every read/write allow above so a
    # hidden path nested inside a writable or readable path stays hidden.
    rules.extend(
        rule
        for path in invocation.capabilities.hidden_paths
        for rule in (
            f"(deny file-read* (subpath {json.dumps(str(path.resolve()))}))",
            f"(deny file-write* (subpath {json.dumps(str(path.resolve()))}))",
        )
    )
    if invocation.capabilities.network is NetworkAccess.NONE:
        rules.append("(deny network*)")
    elif invocation.capabilities.network is NetworkAccess.PUBLIC:
        # PUBLIC only opens remote network access; without this, nothing
        # constrains connections to host unix-domain sockets (the SSH agent,
        # an editor's IPC socket, ...), so deny them by default and allow
        # only the sockets declared below and the system sockets above.
        rules.append("(deny network-outbound (remote unix-socket))")
        rules.extend(
            f"(allow network-outbound (literal {json.dumps(path)}))"
            for path in _SYSTEM_UNIX_SOCKETS
        )
    rules.extend(
        "(allow network-outbound "
        f"(remote unix-socket (path-literal {json.dumps(str(path.resolve()))})))"
        for path in invocation.capabilities.unix_sockets
    )
    return "\n".join(rules) + "\n"
