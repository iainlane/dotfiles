# Isolation

Every agent process runs in a sandbox built from an explicit declaration of what
it may touch. The domain layer declares readable paths, writable paths, hidden
paths, and network access; the platform adapters expose only runtime system
paths and those declared capabilities.

On macOS, Seatbelt applies each declaration directly. On Linux, Bubblewrap
starts from an empty root and mounts only the declared paths, so undeclared host
paths remain hidden without additional deny rules. Bubblewrap also supplies
private PID, IPC, UTS, and device namespaces.

## Seatbelt

Seatbelt imports macOS's system runtime policy so dynamic executables can start,
and permits filesystem metadata for path resolution. File contents remain
limited to system runtime data and the paths declared by the invocation.

A host integration test starts the pinned Git through the real profile and
verifies that an undeclared file cannot be read or written. A separate opt-in
probe makes a real HTTPS connection through the same profile and explicit CA
bundle.

## The candidate

Claude can write its instance workspace, state, cache, and temporary directory,
and has public network access for realistic repository work.

Claude receives private configuration, cache, state, and temporary directories.
The assembled rules and output styles are linked into that private
configuration. The suite omits production plugins and marketplaces, loads no
repository project settings, and supplies an empty strict MCP configuration.
Repository source text remains available as task context because fixture
revisions are reviewed inputs to the suite.

The fixture's Nix tool path and private temporary directory are applied through
the run-specific Claude settings, so they are available to model-run
subprocesses. Claude runs those commands through the pinned Nix Bash, keeping
shell startup within the declared environment.

Subscription-backed invocations have no dollar budget; API-backed invocations
receive the configured API budget. The suite sets no candidate deadline.

Prompt variants are built through the host Nix daemon, which is reached through
a declared isolation capability.

## Claude credentials

On macOS, PyObjC opens Claude's complete OAuth credential through the Security
framework when the run starts. One LocalAuthentication context is retained for
the run, so later credential reconciliation reuses that initial Keychain
authentication and does not prompt again. Linux loads the equivalent normal
Claude credentials file. The run retains that credential as a renewable session.

Candidate processes receive only the current access token, through an inherited
file descriptor. If Claude rejects it, the candidate uses the pinned client's
bidirectional SDK protocol to request a fresh OAuth access token from the suite.
The suite coordinates through the pinned client's cross-process OAuth and
storage-write locks and reloads the shared credential only while reconciling a
refresh. It adopts a rotation completed by another process or safely persists
the complete newly rotated document, then returns only the access token.
Credential files, locks, and Keychain namespaces follow the pinned client's
secure-storage directory and custom-OAuth selection.

Parallel candidates share the same refresh operation and can continue across
token rotations; credential lifetime is not coupled to candidate runtime. The
macOS sandbox denies both Keychain service IPC and Claude's redundant `security`
prefetch process, so no OAuth secret enters the candidate environment and
candidates cannot trigger their own Keychain prompts.

## The judge

Codex can write its own state, cache, temporary directory, and exact result
file. It cannot read the host credential. The suite starts the pinned client as
an app server and supplies its current access token through the external-auth
protocol after the sandboxed process starts.

The judge's model permission profile denies filesystem and network access; the
instance-specific MCP server supplies the suite's evaluation or improvement
evidence. The host sandbox permits the Codex client itself to reach the model
service, while its evidence tree remains read-only.

Nix supplies Codex with an explicit CA bundle through `SSL_CERT_FILE`, and that
bundle is also declared as a readable capability. This keeps model TLS
independent of macOS Security services, which the sandbox denies to prevent
credential access.

Codex reads the host-managed configuration required by the client. The instance
configuration records an explicit disabled entry for every managed MCP server
discovered before the run and enables the suite's bespoke evidence server. Known
limitation: current Codex configuration precedence can retain host-managed
servers despite those instance entries, and isolating that managed layer is
deliberately deferred.

Configuration, cache, and temporary files remain private to each judge instance.

## Codex credentials

The run-scoped Codex authentication broker resolves the ordinary client home
from `CODEX_HOME`, with `~/.codex` as the client default, and owns all access to
its `auth.json`. When app-server reports a rejected access token, the broker
reloads the shared credential, adopts a rotation already completed by another
owner or competes for the refresh at the OAuth authority, and atomically
reconciles a successful response. If an ordinary Codex process wins that race,
the broker watches `auth.json` and adopts its completed write.

Only the resulting access token and account identifier cross the external-auth
protocol; refresh tokens are never written to instance state or result trees.

## Git

Git uses a private home, disabled system and global configuration, a fixed
identity, disabled hooks, signing, credential helpers, terminal prompts, and SSH
commands.
