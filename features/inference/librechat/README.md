# LibreChat

Bonington and Melton run the nixpkgs LibreChat package with native MongoDB,
PostgreSQL with pgvector, Meilisearch, Redis, RustFS and CodeAPI services.
LibreChat listens on `http://127.0.0.1:3080`. The service uses the user's
private state directory, which defaults to `$XDG_DATA_HOME/librechat`.

The service starts the databases first and waits for a personal account. After
activation, create a password file with mode `0600`, then run:

```sh
librechatctl bootstrap --email you@example.com --password-file /private/password
```

Remove the password file afterwards. Bootstrap creates the first administrator
and a personal agent for each configured provider. Repeating the command repairs
agent permissions and creates agents for newly enabled providers. Existing
passwords and agent settings are preserved. Restart the service after changing
provider options, and rerun bootstrap when enabling a new provider.

## Providers

Set these Home Manager options under `dotfiles.inference.librechat`:

| Option              | Default                            | Behaviour                                                        |
| ------------------- | ---------------------------------- | ---------------------------------------------------------------- |
| `ollamaUrl`         | `http://127.0.0.1:11434`           | Uses the OpenAI-compatible Ollama API. Null disables it.         |
| `anthropicKeyFile`  | `dotfiles.ai.anthropicApiKeyFile`  | Reads a host-owned API key at runtime. Null disables Anthropic.  |
| `openaiKeyFile`     | `dotfiles.ai.openaiApiKeyFile`     | Reads a host-owned API key at runtime. Null disables OpenAI.     |
| `openrouterKeyFile` | `dotfiles.ai.openrouterApiKeyFile` | Reads a host-owned API key at runtime. Null disables OpenRouter. |

The shared credential options default to null. Set them to decrypted runtime
paths, such as SOPS secret paths. A configured unreadable, empty or multiline
credential file fails startup. Credentials are excluded from the Nix store and
conversation guests. This integration uses API keys; it does not configure
workload identity federation.

Configure initial models for new personal agents through `models`. When
`ollamaUrl` uses its default, the host's model loader includes `qwen3:4b` and
`qwen3-embedding:0.6b`. Retrieval uses Ollama embeddings when Ollama is enabled,
or OpenAI embeddings when an OpenAI key is configured. Retrieval is disabled
when neither embedding provider is configured. Tika and chat-history migration
are excluded.

New personal agents enable File Search when retrieval is configured. If you
enable retrieval for an existing agent, add File Search in the agent builder.
Bootstrap preserves the tools of existing agents.

## Tools and skills

The final `dotfiles.ai.mcpServers` and `dotfiles.ai.skills` registries supply
the server configuration. Native HTTP MCPs run through LibreChat on the host.
Local stdio MCPs run in the conversation's Linux VM. Standard local definitions
are re-evaluated for Linux. A custom definition with host paths or credentials
needs an explicit Linux replacement in `guestMcpServers`.

`dotfiles.ai.mcpNativeServers` describes native HTTP equivalents of shared stdio
wrappers. Its `sourceCommand` must match the selected shared definition.
`headerFiles` resolves credentials on the host. A change to the final registry
therefore cannot silently select an unrelated HTTP equivalent.

`dotfiles.ai.skillRuntimeDependencies` specifies Nix package attributes for each
shared skill entry. The host installs these tools, and LibreChat resolves the
same attributes for Linux. AgentsView is replaced by a bounded, read-only host
broker in the guest. Shared skills and scripts are available at
`/usr/share/agent-skills` inside the guest. Code Interpreter provides Bash,
Python, Node and Bun for shell and file operations.

## Conversation workspaces

Code Interpreter and local MCPs share `/mnt/data` in one Linux VM per
conversation. The host uses KVM on Linux and HVF on Darwin. Guests receive no
host filesystem mounts. Public HTTP(S) uses Iron through explicit QEMU network
forwards. Direct guest network access is blocked. Iron rejects private and host
addresses, and injects the host's `gh` credential only into approved GitHub
HTTPS requests containing the guest placeholder. GitHub authentication therefore
uses the host's existing `gh auth` account. The credential transform uses a
private Unix socket. The guest firewall blocks workspace processes from directly
reaching the control, runner and MCP proxy ports.

The NixOS feature adds the user to `kvm`. Start a new login session after the
first activation so the user service receives the updated group membership.

RunStart and PostToolBatch hooks automatically add workspace reminders to the
model context. No status tool call is required. LibreChat inserts hook context
through its native hook mechanism.

The controller checkpoints workspace files before stopping an idle VM after 15
minutes. MCP processes stop before checkpointing and restart after restoration.
Processes and browser tabs do not persist. Activity, including CodeAPI
prewarming, extends the 30-day file retention period. Expiry deletes unpushed
work. Health probes do not extend retention.

A failed checkpoint keeps the VM running and retries during shutdown. Service
shutdown on Linux waits until the checkpoint succeeds. Darwin allows up to 60
seconds for shutdown. After an ungraceful controller exit, the next workspace
operation stops the old VM through its private QMP socket before restarting it.
Recovery guarantees the last committed checkpoint; a crash may lose later
changes.

To discard a workspace explicitly, finish active calls and run:

```sh
librechatctl reset --conversation CONVERSATION_UUID
```

The reset deletes workspace files, including unpushed work. The next reminder
reports the new generation. A quarantined workspace requires operator inspection
before this reset. Its files and checkpoint remain under
`$XDG_DATA_HOME/librechat/sessions/RUNTIME_ID` until reset or expiry.

## Operations

On Linux, use `systemctl --user status librechat` and
`journalctl --user -u librechat`. On Darwin, the Home Manager launchd agent
writes `~/Library/Logs/librechat.log`. Darwin startup waits up to 30 seconds for
the configured SOPS launchd job to finish successfully before reading
credentials. Back up the complete private state directory while the service is
stopped. Preserve `secrets` with the databases, because the application uses
those secrets for authentication and encryption.

On Darwin, launchd can force the service to stop after its 60-second shutdown
limit. To drain active calls or retry a failed checkpoint without that limit,
send the controller a signal before switching Home Manager or logging out:

```sh
launchctl kill SIGTERM "gui/$(id -u)/org.nix-community.home.librechat"
```

Wait for the controller and its VMs to exit before proceeding. Check the agent
with `launchctl list org.nix-community.home.librechat` and inspect the log if
shutdown is delayed. A successful stop exits zero and does not restart the
agent. `launchctl kickstart "gui/$(id -u)/org.nix-community.home.librechat"`
starts the service again.

This feature defines deployment configuration. Building or evaluating the flake
does not activate services or download Ollama models onto a running host.
