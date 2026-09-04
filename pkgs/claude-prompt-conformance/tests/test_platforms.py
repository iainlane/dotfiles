import errno
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from pathlib import Path
from threading import Event
from typing import cast

import msgspec
import pytest

from claude_prompt_conformance.claude_storage import (
    ClaudeCustomOAuthUrlUnsupportedError,
    ClaudeSecureStorage,
)
from claude_prompt_conformance.credential_lock import (
    ClaudeCredentialRefreshLock,
    ClaudeCredentialStorageLock,
    CredentialLockReleaseError,
    CredentialLockTimeoutError,
)
from claude_prompt_conformance.credentials import ClaudeCredential
from claude_prompt_conformance.models import (
    ClaudeKeychainNamespace,
    KeychainItem,
    KeychainRevision,
    NetworkAccess,
    ProcessCapabilities,
    ProcessExchange,
    ProcessInvocation,
    ProcessOutputRecord,
    ProcessResult,
    RepositorySpec,
)
from claude_prompt_conformance.platforms.darwin import (
    DarwinClaudeCredentialStore,
    DarwinProcessRunner,
    IsolationProfileDirectoryCreateError,
    IsolationProfileWriteError,
    KeychainReadError,
    PyObjCKeychain,
    claude_keychain_namespace,
    seatbelt_profile,
)
from claude_prompt_conformance.platforms.linux import (
    LinuxProcessRunner,
    bubblewrap_command,
)
from claude_prompt_conformance.ports import ProcessSession
from claude_prompt_conformance.process import ProcessSupervisor, SandboxInfoPipe
from claude_prompt_conformance.protocols.claude import ClaudeOAuth
from claude_prompt_conformance.workspace import GitRepositoryMaterialiser

from .helpers import ExitFailingLock


@dataclass
class FakeKeychain:
    value: str
    revision: KeychainRevision = field(default_factory=lambda: KeychainRevision(1.0))
    persistent_reference: bytes = b"keychain-item"
    replacement_after_update: str | None = None
    secret_readable: bool = True

    def generic_password(self, account: str, service: str) -> KeychainItem:
        if not self.secret_readable:
            raise KeychainReadError(-25308)

        return KeychainItem(
            self.value.encode(),
            self.revision,
            self.persistent_reference,
        )

    def generic_password_revision(
        self,
        persistent_reference: bytes,
    ) -> KeychainRevision:
        if persistent_reference != self.persistent_reference:
            raise KeychainReadError(-25300)
        return self.revision

    def update_generic_password(
        self,
        persistent_reference: bytes,
        value: bytes,
    ) -> None:
        if persistent_reference != self.persistent_reference:
            raise KeychainReadError(-25300)
        self.value = value.decode()
        self.revision = KeychainRevision(self.revision.timestamp + 1)
        if self.replacement_after_update is not None:
            self.value = self.replacement_after_update
            self.revision = KeychainRevision(self.revision.timestamp + 1)


class TlsProbeResult(msgspec.Struct, frozen=True, forbid_unknown_fields=True):
    """The complete successful outcome of the sandboxed HTTPS probe."""

    tls: bool


INFO_DESCRIPTOR = 9


def invocation(
    tmp_path: Path,
    network: NetworkAccess,
    hidden_paths: tuple[Path, ...] = (),
) -> ProcessInvocation:
    writable = tmp_path / "writable"
    writable.mkdir()
    readable = tmp_path / "readable"
    readable.mkdir()
    writable_file = tmp_path / "credential"
    writable_file.write_text("credential")
    actual_socket = tmp_path / "actual-socket"
    actual_socket.write_text("")
    unix_socket = tmp_path / "socket"
    unix_socket.symlink_to(actual_socket)
    return ProcessInvocation(
        command=("tool", "argument"),
        cwd=tmp_path,
        environment={"PATH": "/bin"},
        capabilities=ProcessCapabilities(
            writable_paths=(writable,),
            network=network,
            readable_paths=(readable,),
            writable_files=(writable_file,),
            hidden_paths=hidden_paths,
            unix_sockets=(unix_socket,),
        ),
        stdout=tmp_path / "stdout",
        stderr=tmp_path / "stderr",
    )


@pytest.mark.parametrize(
    ("environment", "expected_storage", "expected_namespace"),
    (
        (
            {"USER": "test-user"},
            ClaudeSecureStorage(
                Path("/controlled/home/.claude"),
                "Claude Code-credentials",
            ),
            ClaudeKeychainNamespace("test-user", "Claude Code-credentials"),
        ),
        (
            {
                "USER": "test-user",
                "CLAUDE_CONFIG_DIR": "/controlled/config",
            },
            ClaudeSecureStorage(
                Path("/controlled/config"),
                "Claude Code-credentials-7fe7324c",
            ),
            ClaudeKeychainNamespace(
                "test-user",
                "Claude Code-credentials-7fe7324c",
            ),
        ),
        (
            {
                "USER": "test-user",
                "CLAUDE_CONFIG_DIR": "/controlled//config",
            },
            ClaudeSecureStorage(
                Path("/controlled/config"),
                "Claude Code-credentials-74085e32",
            ),
            ClaudeKeychainNamespace(
                "test-user",
                "Claude Code-credentials-74085e32",
            ),
        ),
        (
            {
                "USER": "test-user",
                "CLAUDE_CONFIG_DIR": "/controlled/config",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/secure/config",
            },
            ClaudeSecureStorage(
                Path("/secure/config"),
                "Claude Code-credentials-bb45b5d2",
            ),
            ClaudeKeychainNamespace(
                "test-user",
                "Claude Code-credentials-bb45b5d2",
            ),
        ),
        (
            {
                "USER": "test-user",
                "CLAUDE_CONFIG_DIR": "/controlled/config",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "",
            },
            ClaudeSecureStorage(
                Path("/controlled/home/.claude"),
                "Claude Code-credentials",
            ),
            ClaudeKeychainNamespace("test-user", "Claude Code-credentials"),
        ),
        (
            {
                "USER": "not a valid account",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/secure/cafe\u0301",
            },
            ClaudeSecureStorage(
                Path("/secure/café"),
                "Claude Code-credentials-666542c1",
            ),
            ClaudeKeychainNamespace(
                "claude-code-user",
                "Claude Code-credentials-666542c1",
            ),
        ),
        (
            {
                "USER": "test-user",
                "CLAUDE_CONFIG_DIR": "/controlled/cafe\u0301",
                "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://claude.fedstart.com/",
            },
            ClaudeSecureStorage(
                Path("/controlled/café"),
                "Claude Code-custom-oauth-credentials-058341f5",
            ),
            ClaudeKeychainNamespace(
                "test-user",
                "Claude Code-custom-oauth-credentials-058341f5",
            ),
        ),
    ),
)
def test_claude_secure_storage_matches_the_pinned_client(
    environment: dict[str, str],
    expected_storage: ClaudeSecureStorage,
    expected_namespace: ClaudeKeychainNamespace,
) -> None:
    storage = ClaudeSecureStorage.from_environment(
        environment,
        Path("/controlled/home"),
    )

    assert (storage, claude_keychain_namespace(environment, storage)) == (
        expected_storage,
        expected_namespace,
    )


def test_claude_secure_storage_rejects_an_unapproved_custom_oauth_url() -> None:
    environment = {"CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://unapproved.invalid/"}

    with pytest.raises(ClaudeCustomOAuthUrlUnsupportedError) as raised:
        ClaudeSecureStorage.from_environment(environment, Path("/controlled/home"))

    assert raised.value == ClaudeCustomOAuthUrlUnsupportedError(
        "https://unapproved.invalid"
    )


def test_darwin_backend_maps_capabilities_to_a_seatbelt_profile(
    tmp_path: Path,
) -> None:
    process = invocation(tmp_path, NetworkAccess.NONE)
    assert seatbelt_profile(process) == (
        "(version 1)\n"
        "(allow default)\n"
        '(import "system.sb")\n'
        '(deny process-exec (literal "/usr/bin/security"))\n'
        '(deny mach-lookup (global-name "com.apple.SecurityServer") '
        '(global-name-prefix "com.apple.securityd"))\n'
        "(deny file-read*)\n"
        "(deny file-write*)\n"
        "(allow file-read-metadata)\n"
        '(allow file-write* (literal "/dev/null"))\n'
        '(allow file-read* (subpath "/Library"))\n'
        '(allow file-read* (subpath "/System"))\n'
        '(allow file-read* (subpath "/bin"))\n'
        '(allow file-read* (subpath "/dev"))\n'
        '(allow file-read* (subpath "/nix/store"))\n'
        '(allow file-read* (subpath "/private/etc"))\n'
        '(allow file-read* (subpath "/private/var/db/timezone"))\n'
        '(allow file-read* (subpath "/private/var/select"))\n'
        '(allow file-read* (subpath "/usr"))\n'
        f'(allow file-read* (subpath "{tmp_path / "readable"}"))\n'
        f'(allow file-read* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "credential"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "actual-socket"}"))\n'
        f'(allow file-write* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-write* (literal "{tmp_path / "credential"}"))\n'
        "(deny network*)\n"
        "(allow network-outbound "
        f'(remote unix-socket (path-literal "{tmp_path / "actual-socket"}")))\n'
    )


def test_darwin_backend_hides_a_path_nested_inside_a_writable_path(
    tmp_path: Path,
) -> None:
    hidden = tmp_path / "writable" / "secret"
    process = invocation(tmp_path, NetworkAccess.NONE, hidden_paths=(hidden,))

    assert seatbelt_profile(process) == (
        "(version 1)\n"
        "(allow default)\n"
        '(import "system.sb")\n'
        '(deny process-exec (literal "/usr/bin/security"))\n'
        '(deny mach-lookup (global-name "com.apple.SecurityServer") '
        '(global-name-prefix "com.apple.securityd"))\n'
        "(deny file-read*)\n"
        "(deny file-write*)\n"
        "(allow file-read-metadata)\n"
        '(allow file-write* (literal "/dev/null"))\n'
        '(allow file-read* (subpath "/Library"))\n'
        '(allow file-read* (subpath "/System"))\n'
        '(allow file-read* (subpath "/bin"))\n'
        '(allow file-read* (subpath "/dev"))\n'
        '(allow file-read* (subpath "/nix/store"))\n'
        '(allow file-read* (subpath "/private/etc"))\n'
        '(allow file-read* (subpath "/private/var/db/timezone"))\n'
        '(allow file-read* (subpath "/private/var/select"))\n'
        '(allow file-read* (subpath "/usr"))\n'
        f'(allow file-read* (subpath "{tmp_path / "readable"}"))\n'
        f'(allow file-read* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "credential"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "actual-socket"}"))\n'
        f'(allow file-write* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-write* (literal "{tmp_path / "credential"}"))\n'
        f'(deny file-read* (subpath "{hidden}"))\n'
        f'(deny file-write* (subpath "{hidden}"))\n'
        "(deny network*)\n"
        "(allow network-outbound "
        f'(remote unix-socket (path-literal "{tmp_path / "actual-socket"}")))\n'
    )


def test_darwin_backend_denies_undeclared_unix_sockets_under_public_network(
    tmp_path: Path,
) -> None:
    process = invocation(tmp_path, NetworkAccess.PUBLIC)

    assert seatbelt_profile(process) == (
        "(version 1)\n"
        "(allow default)\n"
        '(import "system.sb")\n'
        '(deny process-exec (literal "/usr/bin/security"))\n'
        '(deny mach-lookup (global-name "com.apple.SecurityServer") '
        '(global-name-prefix "com.apple.securityd"))\n'
        "(deny file-read*)\n"
        "(deny file-write*)\n"
        "(allow file-read-metadata)\n"
        '(allow file-write* (literal "/dev/null"))\n'
        '(allow file-read* (subpath "/Library"))\n'
        '(allow file-read* (subpath "/System"))\n'
        '(allow file-read* (subpath "/bin"))\n'
        '(allow file-read* (subpath "/dev"))\n'
        '(allow file-read* (subpath "/nix/store"))\n'
        '(allow file-read* (subpath "/private/etc"))\n'
        '(allow file-read* (subpath "/private/var/db/timezone"))\n'
        '(allow file-read* (subpath "/private/var/select"))\n'
        '(allow file-read* (subpath "/usr"))\n'
        f'(allow file-read* (subpath "{tmp_path / "readable"}"))\n'
        f'(allow file-read* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "credential"}"))\n'
        f'(allow file-read* (literal "{tmp_path / "actual-socket"}"))\n'
        f'(allow file-write* (subpath "{tmp_path / "writable"}"))\n'
        f'(allow file-write* (literal "{tmp_path / "credential"}"))\n'
        "(deny network-outbound (remote unix-socket))\n"
        '(allow network-outbound (literal "/private/var/run/mDNSResponder"))\n'
        "(allow network-outbound "
        f'(remote unix-socket (path-literal "{tmp_path / "actual-socket"}")))\n'
    )


@dataclass
class FakeProcesses:
    """Record the command a Darwin process runner submits, without executing it."""

    invocations: list[tuple[ProcessInvocation, tuple[str, ...]]] = field(
        default_factory=list
    )

    def run(
        self, invocation: ProcessInvocation, command: tuple[str, ...]
    ) -> ProcessResult:
        self.invocations.append((invocation, command))
        return ProcessResult(0)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        command: tuple[str, ...],
        session: ProcessSession,
    ) -> ProcessResult:
        self.invocations.append((invocation, command))
        return ProcessResult(0)


def test_darwin_process_runner_creates_a_missing_profile_directory(
    tmp_path: Path,
) -> None:
    instance = tmp_path / "nested" / "instance"
    process = replace(
        invocation(tmp_path, NetworkAccess.NONE),
        stdout=instance / "stdout",
        stderr=instance / "stderr",
    )
    processes = FakeProcesses()
    runner = DarwinProcessRunner("/usr/bin/sandbox-exec", processes)

    result = runner.run(process)

    profile = instance / "stdout.sb"
    assert (
        result,
        profile.read_text(),
        processes.invocations,
    ) == (
        ProcessResult(0),
        seatbelt_profile(process),
        [
            (
                process,
                (
                    "/usr/bin/sandbox-exec",
                    "-f",
                    str(profile),
                    *process.command,
                ),
            )
        ],
    )


def test_darwin_process_runner_maps_a_profile_directory_create_failure(
    tmp_path: Path,
) -> None:
    blocked = tmp_path / "blocked"
    blocked.write_text("occupied by a file, not a directory")
    process = replace(
        invocation(tmp_path, NetworkAccess.NONE),
        stdout=blocked / "instance" / "stdout",
        stderr=blocked / "instance" / "stderr",
    )
    runner = DarwinProcessRunner("/usr/bin/sandbox-exec", FakeProcesses())

    with pytest.raises(IsolationProfileDirectoryCreateError) as raised:
        runner.run(process)

    assert raised.value.directory == blocked / "instance"


def test_darwin_process_runner_maps_a_profile_write_failure(tmp_path: Path) -> None:
    process = invocation(tmp_path, NetworkAccess.NONE)
    profile = process.stdout.with_suffix(".sb")
    profile.mkdir()
    runner = DarwinProcessRunner("/usr/bin/sandbox-exec", FakeProcesses())

    with pytest.raises(IsolationProfileWriteError) as raised:
        runner.run(process)

    assert raised.value.destination == profile


@pytest.mark.skipif(sys.platform != "darwin", reason="requires macOS Seatbelt")
@pytest.mark.host_integration
def test_darwin_backend_materialises_a_repository_with_runtime_access(
    tmp_path: Path,
) -> None:
    git_program = shutil.which("git")
    if git_program is None:
        pytest.fail("Git is required for the Darwin host integration test")

    control = tmp_path / "control"
    control.mkdir()
    clang = shutil.which("clang")
    if clang is None:
        pytest.fail("Clang is required for the Darwin Keychain isolation probe")
    keychain_probe = control / "keychain-probe"
    subprocess.run(
        (
            clang,
            str(Path(__file__).parent / "fixtures" / "keychain_probe.c"),
            "-framework",
            "Security",
            "-framework",
            "CoreFoundation",
            "-o",
            str(keychain_probe),
        ),
        check=True,
    )
    source = control / "source"
    source.mkdir()
    _run_git(git_program, source, "init", "--quiet")
    _run_git(git_program, source, "config", "user.name", "Test Author")
    _run_git(
        git_program,
        source,
        "config",
        "user.email",
        "test-author@example.invalid",
    )
    (source / "tracked.txt").write_text("tracked\n")
    _run_git(git_program, source, "add", "tracked.txt")
    _run_git(git_program, source, "commit", "--quiet", "-m", "base")
    comparison_revision = _run_git(git_program, source, "rev-parse", "HEAD").strip()
    (source / "tracked.txt").write_text("candidate\n")
    _run_git(git_program, source, "commit", "--quiet", "-am", "candidate")
    revision = _run_git(git_program, source, "rev-parse", "HEAD").strip()

    workspace = tmp_path / "workspace"
    workspace.mkdir()
    runner = DarwinProcessRunner("/usr/bin/sandbox-exec", ProcessSupervisor())

    GitRepositoryMaterialiser(runner, git_program).materialise(
        RepositorySpec(source.as_uri(), revision),
        workspace,
        control,
        os.environ["PATH"],
        comparison_revision,
    )

    configuration_keys = (
        "user.name",
        "user.email",
        "commit.gpgSign",
        "tag.gpgSign",
        "core.hooksPath",
        "credential.helper",
    )
    assert (
        _run_git(git_program, workspace, "branch", "--show-current").strip(),
        _run_git(git_program, workspace, "rev-parse", "HEAD").strip(),
        (workspace / "tracked.txt").read_text(),
        tuple(
            _run_git(
                git_program, workspace, "config", "--local", "--get", key
            ).removesuffix("\n")
            for key in configuration_keys
        ),
    ) == (
        "prompt-conformance",
        revision,
        "candidate\n",
        (
            "Prompt Conformance Candidate",
            "prompt-conformance@example.invalid",
            "false",
            "false",
            str(control / "hooks"),
            "",
        ),
    )

    private_file = tmp_path / "private.txt"
    private_file.write_text("private\n")
    readable_file = tmp_path / "readable.txt"
    readable_file.write_text("readable\n")
    isolation_check = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import os, subprocess, sys\n"
                "denied = []\n"
                "for name, flags in "
                "(('read', os.O_RDONLY), ('write', os.O_WRONLY | os.O_TRUNC)):\n"
                "    try:\n"
                "        descriptor = os.open(sys.argv[1], flags)\n"
                "    except PermissionError:\n"
                "        denied.append(name)\n"
                "    else:\n"
                "        os.close(descriptor)\n"
                "try:\n"
                "    subprocess.run(['/usr/bin/security', 'help'], check=False)\n"
                "except PermissionError:\n"
                "    denied.append('keychain')\n"
                "with open(sys.argv[2]) as source:\n"
                "    sys.stdout.write(source.read())\n"
                "sys.exit(0 if denied == ['read', 'write', 'keychain'] else 1)\n"
            ),
            str(private_file),
            str(readable_file),
        ),
        cwd=control,
        environment={"PATH": os.environ["PATH"]},
        capabilities=ProcessCapabilities(
            writable_paths=(workspace, control),
            readable_paths=(readable_file,),
            network=NetworkAccess.NONE,
        ),
        stdout=control / "isolation.stdout",
        stderr=control / "isolation.stderr",
    )

    isolation_result = runner.run(isolation_check)
    keychain_check = ProcessInvocation(
        command=(str(keychain_probe),),
        cwd=control,
        environment={},
        capabilities=ProcessCapabilities(
            writable_paths=(workspace, control),
            network=NetworkAccess.NONE,
        ),
        stdout=control / "keychain.stdout",
        stderr=control / "keychain.stderr",
    )
    keychain_result = runner.run(keychain_check)

    assert (
        isolation_result,
        isolation_check.stdout.read_text(),
        isolation_check.stderr.read_text(),
        keychain_result,
        keychain_check.stdout.read_text(),
        keychain_check.stderr.read_text(),
        private_file.read_text(),
        readable_file.read_text(),
    ) == (
        ProcessResult(0),
        "readable\n",
        "",
        ProcessResult(0),
        "-50\n",
        "",
        "private\n",
        "readable\n",
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="requires macOS Seatbelt")
@pytest.mark.host_integration
def test_darwin_backend_uses_an_explicit_tls_certificate_bundle(
    tmp_path: Path,
) -> None:
    certificate_bundle = Path(
        os.environ.get("SSL_CERT_FILE")
        or os.environ.get("NIX_SSL_CERT_FILE")
        or "/etc/ssl/certs/ca-certificates.crt"
    ).resolve()
    process = ProcessInvocation(
        command=(
            sys.executable,
            "-c",
            (
                "import json, urllib.error, urllib.request\n"
                "try:\n"
                "    urllib.request.urlopen('https://chatgpt.com')\n"
                "except urllib.error.HTTPError:\n"
                "    pass\n"
                "print(json.dumps({'tls': True}))\n"
            ),
        ),
        cwd=tmp_path,
        environment={
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
            "SSL_CERT_FILE": str(certificate_bundle),
            "TZ": "UTC",
        },
        capabilities=ProcessCapabilities(
            writable_paths=(tmp_path,),
            readable_paths=(certificate_bundle,),
            network=NetworkAccess.PUBLIC,
        ),
        stdout=tmp_path / "tls.stdout",
        stderr=tmp_path / "tls.stderr",
    )

    result = DarwinProcessRunner("/usr/bin/sandbox-exec", ProcessSupervisor()).run(
        process
    )

    assert (
        result,
        msgspec.json.decode(process.stdout.read_bytes(), type=TlsProbeResult),
        process.stderr.read_text(),
    ) == (ProcessResult(0), TlsProbeResult(tls=True), "")


def _run_git(git_program: str, repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        (git_program, "-C", str(repository), *arguments),
        check=True,
        capture_output=True,
        env=(
            os.environ
            | {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        ),
        text=True,
    )

    return result.stdout


def test_linux_backend_maps_capabilities_to_bubblewrap_arguments(
    tmp_path: Path,
) -> None:
    process = invocation(tmp_path, NetworkAccess.NONE)
    command = bubblewrap_command("/bin/bwrap", process, INFO_DESCRIPTOR)
    system_paths = (
        "/bin",
        "/etc/group",
        "/etc/hosts",
        "/etc/localtime",
        "/etc/nsswitch.conf",
        "/etc/passwd",
        "/etc/resolv.conf",
        "/etc/ssl",
        "/lib",
        "/lib64",
        "/nix/store",
        "/run/current-system",
        "/usr",
    )
    private_directories = {
        Path("/etc"),
        Path("/nix"),
        Path("/run"),
        tmp_path,
        *(parent for parent in tmp_path.parents if parent != Path("/")),
    }
    directory_arguments = tuple(
        argument
        for directory in sorted(
            private_directories, key=lambda path: (len(path.parts), str(path))
        )
        for argument in ("--dir", str(directory))
    )
    system_arguments = tuple(
        argument for path in system_paths for argument in ("--ro-bind-try", path, path)
    )
    assert command == (
        "/bin/bwrap",
        "--die-with-parent",
        "--info-fd",
        str(INFO_DESCRIPTOR),
        "--new-session",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--tmpfs",
        "/",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        *directory_arguments,
        *system_arguments,
        "--ro-bind",
        str(tmp_path / "readable"),
        str(tmp_path / "readable"),
        "--bind",
        str(tmp_path / "writable"),
        str(tmp_path / "writable"),
        "--bind",
        str(tmp_path / "credential"),
        str(tmp_path / "credential"),
        "--ro-bind",
        str(tmp_path / "actual-socket"),
        str(tmp_path / "socket"),
        "--unshare-net",
        "--chdir",
        str(tmp_path),
        "--",
        "tool",
        "argument",
    )


def test_linux_backend_hides_a_path_nested_inside_a_writable_path(
    tmp_path: Path,
) -> None:
    hidden = tmp_path / "writable" / "secret"
    process = invocation(tmp_path, NetworkAccess.NONE, hidden_paths=(hidden,))

    command = bubblewrap_command("/bin/bwrap", process, INFO_DESCRIPTOR)

    system_paths = (
        "/bin",
        "/etc/group",
        "/etc/hosts",
        "/etc/localtime",
        "/etc/nsswitch.conf",
        "/etc/passwd",
        "/etc/resolv.conf",
        "/etc/ssl",
        "/lib",
        "/lib64",
        "/nix/store",
        "/run/current-system",
        "/usr",
    )
    private_directories = {
        Path("/etc"),
        Path("/nix"),
        Path("/run"),
        tmp_path,
        tmp_path / "writable",
        *(parent for parent in tmp_path.parents if parent != Path("/")),
    }
    directory_arguments = tuple(
        argument
        for directory in sorted(
            private_directories, key=lambda path: (len(path.parts), str(path))
        )
        for argument in ("--dir", str(directory))
    )
    system_arguments = tuple(
        argument for path in system_paths for argument in ("--ro-bind-try", path, path)
    )
    assert command == (
        "/bin/bwrap",
        "--die-with-parent",
        "--info-fd",
        str(INFO_DESCRIPTOR),
        "--new-session",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--tmpfs",
        "/",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        *directory_arguments,
        *system_arguments,
        "--ro-bind",
        str(tmp_path / "readable"),
        str(tmp_path / "readable"),
        "--bind",
        str(tmp_path / "writable"),
        str(tmp_path / "writable"),
        "--bind",
        str(tmp_path / "credential"),
        str(tmp_path / "credential"),
        "--ro-bind",
        str(tmp_path / "actual-socket"),
        str(tmp_path / "socket"),
        "--tmpfs",
        str(hidden),
        "--unshare-net",
        "--chdir",
        str(tmp_path),
        "--",
        "tool",
        "argument",
    )


@dataclass(frozen=True)
class QuietSession:
    def initial_input(self) -> tuple[bytes, ...]:
        return ()

    def receive(self, record: ProcessOutputRecord) -> ProcessExchange:
        return ProcessExchange()


@dataclass(frozen=True)
class SandboxHandoff:
    """One invocation's sandbox report pipe as the supervisor received it."""

    reported: tuple[str, ...]
    descriptor: int | None
    sandbox: SandboxInfoPipe | None


type SandboxStart = Callable[[LinuxProcessRunner, ProcessInvocation], ProcessResult]


def start_sandbox(
    runner: LinuxProcessRunner, invocation: ProcessInvocation
) -> ProcessResult:
    return runner.run(invocation)


def start_interactive_sandbox(
    runner: LinuxProcessRunner, invocation: ProcessInvocation
) -> ProcessResult:
    return runner.run_interactive(invocation, QuietSession())


def reported_descriptors(command: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(
        command[index + 1]
        for index, argument in enumerate(command)
        if argument == "--info-fd"
    )


@pytest.mark.parametrize(
    "start",
    (start_sandbox, start_interactive_sandbox),
    ids=("batch", "interactive"),
)
def test_linux_backend_hands_the_sandbox_report_pipe_to_the_supervisor(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    start: SandboxStart,
) -> None:
    handoffs: list[SandboxHandoff] = []

    def record(
        command: tuple[str, ...],
        sandbox: SandboxInfoPipe | None,
    ) -> ProcessResult:
        handoffs.append(
            SandboxHandoff(
                reported_descriptors(command),
                None if sandbox is None else sandbox.write_descriptor,
                sandbox,
            )
        )
        return ProcessResult(return_code=0)

    def record_run(
        _supervisor: ProcessSupervisor,
        _invocation: ProcessInvocation,
        command: tuple[str, ...],
        sandbox: SandboxInfoPipe | None = None,
    ) -> ProcessResult:
        return record(command, sandbox)

    def record_run_interactive(
        _supervisor: ProcessSupervisor,
        _invocation: ProcessInvocation,
        command: tuple[str, ...],
        _session: QuietSession,
        sandbox: SandboxInfoPipe | None = None,
    ) -> ProcessResult:
        return record(command, sandbox)

    monkeypatch.setattr(ProcessSupervisor, "run", record_run)
    monkeypatch.setattr(ProcessSupervisor, "run_interactive", record_run_interactive)
    runner = LinuxProcessRunner("/bin/bwrap", ProcessSupervisor())

    result = start(runner, invocation(tmp_path, NetworkAccess.NONE))

    handoff = handoffs[0]
    remaining = (
        None
        if handoff.sandbox is None
        else (handoff.sandbox.read_descriptor, handoff.sandbox.write_descriptor)
    )
    assert (result, handoffs, handoff.reported, remaining) == (
        ProcessResult(return_code=0),
        [handoff],
        (str(handoff.descriptor),),
        (-1, -1),
    )


def test_darwin_keychain_store_round_trips_the_complete_claude_credential(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                    "scopes": ["scope"],
                    "clientId": "credential-client",
                    "futureOauthField": "preserved",
                },
                "mcpOAuth": {"server": {"accessToken": "mcp-token"}},
            }
        )
    )
    keychain = FakeKeychain(original.encode().decode())
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    updated = original.with_oauth(
        ClaudeOAuth(
            "fresh-token",
            "rotated-token",
            2_000,
            scopes=("scope",),
            client_id="credential-client",
        )
    )

    store.load()
    store.mutate(lambda _: updated)

    assert (msgspec.json.decode(keychain.value), keychain.revision) == (
        {
            "claudeAiOauth": {
                "accessToken": "fresh-token",
                "refreshToken": "rotated-token",
                "expiresAt": 2_000,
                "scopes": ["scope"],
                "clientId": "credential-client",
                "futureOauthField": "preserved",
            },
            "mcpOAuth": {"server": {"accessToken": "mcp-token"}},
        },
        KeychainRevision(2.0),
    )


def test_pyobjc_keychain_updates_the_selected_item_without_a_revision_filter(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    authentication = object()
    database = {b"selected-item": b"old", b"other-item": b"untouched"}
    expected_query = {
        "item-list": [b"selected-item"],
        "authentication": authentication,
    }

    class FakeSecurity:
        kSecMatchItemList = "item-list"
        kSecUseAuthenticationContext = "authentication"
        kSecValueData = "value"
        errSecSuccess = 0
        errSecItemNotFound = -25300

        @classmethod
        def SecItemUpdate(
            cls,
            query: dict[str, object],
            attributes: dict[str, bytes],
        ) -> int:
            if query != expected_query:
                return cls.errSecItemNotFound

            [key] = cast(list[bytes], query[cls.kSecMatchItemList])
            if key not in database:
                return cls.errSecItemNotFound

            database[key] = attributes[cls.kSecValueData]
            return cls.errSecSuccess

    monkeypatch.setitem(sys.modules, "Security", FakeSecurity)
    keychain = object.__new__(PyObjCKeychain)
    keychain._authentication = authentication

    keychain.update_generic_password(
        b"selected-item",
        b"new",
    )

    assert database == {b"selected-item": b"new", b"other-item": b"untouched"}


def test_darwin_keychain_store_refreshes_from_the_retained_credential(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    replacement = original.with_oauth(
        ClaudeOAuth("fresh-token", "rotated-token", 2_000)
    )
    keychain = FakeKeychain(original.encode().decode())
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    loaded = store.load()
    keychain.secret_readable = False

    refreshed = store.mutate(lambda _: replacement)

    assert (loaded, refreshed, msgspec.json.decode(keychain.value)) == (
        original,
        replacement,
        replacement.document,
    )


def test_darwin_keychain_store_adopts_a_newer_revision(tmp_path: Path) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    keychain = FakeKeychain(original.encode().decode())
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    store.load()
    keychain.revision = KeychainRevision(2.0)
    concurrent = original.with_oauth(ClaudeOAuth("fresh-token", "rotated-token", 2_000))
    keychain.value = concurrent.encode().decode()

    result = store.mutate(lambda current: current)

    assert (result, msgspec.json.decode(keychain.value), keychain.revision) == (
        concurrent,
        concurrent.document,
        KeychainRevision(2.0),
    )


def test_darwin_keychain_store_preserves_a_rotated_token_after_lock_loss(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    replacement = original.with_oauth(
        ClaudeOAuth("fresh-token", "rotated-token", 2_000)
    )
    keychain = FakeKeychain(original.encode().decode())
    current_lock = tmp_path / ".oauth_refresh.lock"
    displaced_lock = tmp_path / "displaced.lock"
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    store.load()

    def lose_lock(_: ClaudeCredential) -> ClaudeCredential:
        current_lock.rename(displaced_lock)
        current_lock.mkdir()
        return replacement

    result = store.mutate(lose_lock)

    assert (
        result,
        msgspec.json.decode(keychain.value),
        keychain.revision,
        tuple(sorted(path.name for path in tmp_path.iterdir())),
    ) == (
        replacement,
        replacement.document,
        KeychainRevision(2.0),
        (".oauth_refresh.lock", "displaced.lock"),
    )


def test_darwin_keychain_store_coordinates_with_a_pinned_unconditional_writer(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    ours = original.with_oauth(ClaudeOAuth("our-token", "our-refresh", 2_000))
    pinned = original.with_oauth(ClaudeOAuth("pinned-token", "pinned-refresh", 3_000))
    keychain = FakeKeychain(original.encode().decode())
    pinned_read = Event()
    candidate_refreshed = Event()
    release_writers = Event()
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    store.load()

    def pinned_writer() -> ClaudeCredential:
        with ClaudeCredentialStorageLock(tmp_path):
            observed = ClaudeCredential.decode(keychain.value.encode())
            pinned_read.set()
            release_writers.wait()
            keychain.value = pinned.encode().decode()
            keychain.revision = KeychainRevision(keychain.revision.timestamp + 1)
            return observed

    def refresh(_: ClaudeCredential) -> ClaudeCredential:
        candidate_refreshed.set()
        release_writers.wait()
        return ours

    with ThreadPoolExecutor(max_workers=2) as executor:
        pinned_result = executor.submit(pinned_writer)
        pinned_read.wait()
        candidate_result = executor.submit(store.mutate, refresh)
        candidate_refreshed.wait()
        release_writers.set()
        results = (pinned_result.result(), candidate_result.result())

    assert (
        results,
        msgspec.json.decode(keychain.value),
        keychain.revision,
        tuple(path.name for path in tmp_path.iterdir()),
    ) == (
        (original, pinned),
        pinned.document,
        KeychainRevision(2.0),
        (),
    )


def test_darwin_keychain_store_applies_one_storage_lock_retry_sequence(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    replacement = original.with_oauth(
        ClaudeOAuth("fresh-token", "rotated-token", 2_000)
    )
    keychain = FakeKeychain(original.encode().decode())
    occupied = tmp_path / ".storage-write.lock"
    occupied.mkdir()
    elapsed = 0.0

    def monotonic() -> float:
        return elapsed

    def advance(seconds: float) -> None:
        nonlocal elapsed
        elapsed += seconds

    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(
            tmp_path,
            acquisition_attempts=2,
            retry_seconds=lambda _: 0.1,
            monotonic=monotonic,
            sleep=advance,
        ),
    )
    store.load()

    with pytest.raises(CredentialLockTimeoutError) as raised:
        store.mutate(lambda _: replacement)

    assert (
        raised.value,
        elapsed,
        msgspec.json.decode(keychain.value),
        keychain.revision,
    ) == (
        CredentialLockTimeoutError(occupied, 0.1),
        0.1,
        original.document,
        KeychainRevision(1.0),
    )


@pytest.mark.parametrize("failure_at", ("refresh", "storage"))
def test_darwin_keychain_store_preserves_a_result_after_lock_cleanup_failure(
    tmp_path: Path,
    failure_at: str,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    replacement = original.with_oauth(
        ClaudeOAuth("fresh-token", "rotated-token", 2_000)
    )
    keychain = FakeKeychain(original.encode().decode())
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
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        refresh_lock,
        storage_lock,
    )
    store.load()

    result = store.mutate(lambda _: replacement)

    assert (result, msgspec.json.decode(keychain.value), keychain.revision) == (
        replacement,
        replacement.document,
        KeychainRevision(2.0),
    )


def test_darwin_keychain_store_adopts_a_later_host_update(
    tmp_path: Path,
) -> None:
    original = ClaudeCredential.decode(
        msgspec.json.encode(
            {
                "claudeAiOauth": {
                    "accessToken": "oauth-token",
                    "refreshToken": "refresh-token",
                    "expiresAt": 1_000,
                }
            }
        )
    )
    replacement = original.with_oauth(ClaudeOAuth("our-token", "our-refresh", 2_000))
    concurrent = original.with_oauth(ClaudeOAuth("host-token", "host-refresh", 3_000))
    keychain = FakeKeychain(
        original.encode().decode(),
        replacement_after_update=concurrent.encode().decode(),
    )
    store = DarwinClaudeCredentialStore(
        "test-user",
        "Claude Code-credentials",
        keychain,
        ClaudeCredentialRefreshLock(tmp_path),
        ClaudeCredentialStorageLock(tmp_path),
    )
    store.load()

    result = store.mutate(lambda _: replacement)
    adopted = store.mutate(lambda current: current)

    assert (
        result,
        adopted,
        msgspec.json.decode(keychain.value),
        keychain.revision,
    ) == (
        replacement,
        concurrent,
        concurrent.document,
        KeychainRevision(3.0),
    )
