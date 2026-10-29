# LibreChat

Bonington and Melton run a pinned LibreChat fork through the nixpkgs package
with native MongoDB, PostgreSQL with pgvector, Meilisearch, Redis, RustFS and
CodeAPI services. LibreChat listens on `http://127.0.0.1:3080`. The service uses
the user's private state directory, which defaults to
`$XDG_DATA_HOME/librechat`.

The service starts the databases first and waits for a personal account. After
activation, create a password file with mode `0600`, then run:

```sh
librechatctl bootstrap --email you@example.com --name "Your Name" --password-file /private/password
```

Remove the password file afterwards. Bootstrap creates the first administrator
and a personal agent for each configured provider. Repeating the command repairs
agent permissions and creates agents for newly enabled providers. The required
`--name` sets the account's display name on creation and updates it on
subsequent runs. Names are trimmed and must contain 3 to 80 characters. Existing
passwords and agent settings are preserved. Restart the service after changing
provider options, and rerun bootstrap when enabling a new provider.

Bootstrap also repairs the legacy `Ollama` provider value to LibreChat's
canonical `ollama` identifier. The repair preserves the existing agent ID and
its other settings.

## Providers

Select providers and models directly from the model selector. The saved Personal
agents remain under **My Agents**. Use an agent's Pin control to add the agent
to your favourites.

Personal agents use the shared coding instructions and preconfigured tools and
skills. Ordinary chats use the [general assistant prompt], independently of the
agent instructions and tool and skill selections.

New ordinary chats switch on the tools listed by `configureInterface` in
`pkgs/librechat-runtime/src/config.ts`. A tool switched off in the composer of a
new chat stays off in that browser's later new chats. New ordinary chats also
select the configured MCP servers that the chat picker permits. Stored server
selections, including an empty selection, take precedence. MCP tools use
deferred discovery, and a server awaiting authentication does not block the
reply.

[general assistant prompt]: chat-prompt.md

## Chat instructions

The Prompt Library includes **General assistant** as a managed, read-only prompt
from the deployment configuration. Ordinary chats inherit this prompt by
default. Open **Prompts** in the sidebar and select **Preview** from the
prompt's menu. Use **Duplicate to edit** to make an editable copy, then use
**Set as default for ordinary chats** to change your account's default.

Open **Parameters** in the sidebar to inherit the default, enter custom
instructions or select **No instructions** for the conversation. Changing the
default applies to conversations that inherit the default; custom instructions
and explicit opt-out remain independent. Saved agents keep their own
instructions.

Default prompts can use `{{current_model}}`, `{{current_user}}`,
`{{current_date}}`, `{{current_datetime}}` and `{{iso_datetime}}`. LibreChat
resolves these variables for each response. `{{current_model}}` contains the
configured model ID for that response, including when comparing models or
changing models in a conversation. Variables that require user input, such as
`{{topic}}`, cannot be used in default instructions.

The prompt is supplied as system instructions, separately from the user's
message. Using a library prompt in the composer retains LibreChat's normal
message-template behaviour. Edit [chat-prompt.md][general assistant prompt] to
change the deployment prompt. Prompt text is outside the runtime package, so a
text-only edit does not rebuild the conversation VM.

## Provider configuration

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

To leave a shared bundle out of the guests instead, list its name in
`excludeBundles`. LibreChat then omits the bundle's MCP servers and skills, and
the runtime dependencies of those skills.

`dotfiles.ai.mcpNativeServers` describes native HTTP equivalents of shared stdio
wrappers. Its `sourceCommand` must match the selected shared definition.
`headerFiles` resolves credentials on the host. A change to the final registry
therefore cannot silently select an unrelated HTTP equivalent.

LibreChat uses a release-based fork with `mcpSettings.authorizationMode` set to
`nonblocking`. A server that requires authentication remains unavailable until
the user connects it, without delaying ordinary inference. Discovery uses the
server's tools after connection. Known tools use tool search and request sign-in
when called if their credentials have expired. The shared MCP registry does not
need duplicate tool catalogues or individual tool selections.

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

The RunStart hook adds workspace reminders to the model context. No status tool
call is required. LibreChat inserts hook context through its native hook
mechanism. The hook registers conversation activity without booting its VM.
Local MCP discovery uses a separate catalogue VM; the conversation VM starts on
the first code, workspace file or local MCP operation. CodeAPI prewarming is
disabled.

The controller checkpoints workspace files before stopping an idle VM after 15
minutes. MCP processes stop before checkpointing and restart after restoration.
Processes and browser tabs do not persist. Conversation activity extends the
30-day file retention period; only VM operations extend the idle deadline.
Expiry deletes unpushed work. Health probes do not extend retention.

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

The `librechat-startup` flake check runs the generated service command inside
the Nix sandbox with the service manager's initial working directory. It uses
the real host services with temporary state, Unix sockets and TCP ports. The
check creates an administrator and a personal agent with a whole-server MCP
selection, and verifies that repeated bootstrap does not create another agent
version. A loopback model, OAuth provider and MCP exercise an ordinary chat
before authentication, explicit connection and automatic tool discovery. The
check verifies web health and login, restarts the service and verifies login
again. External provider and MCP calls, skills, RAG, workspace hooks and
conversation VMs are outside this check. The existing LibreChat service can
continue running. On Linux, the check uses a NixOS VM to provide sysfs for
MongoDB's allocator. Service manager registration needs a separate host test.

On Melton, run:

```sh
direnv exec . nix build .#checks.aarch64-darwin.librechat-startup
```

This feature defines deployment configuration. Building or evaluating the flake
does not activate services or download Ollama models onto a running host.

## Fork updates

The [LibreChat fork] uses branch `fix/mcp-nonblocking-auth`, based on
`v0.8.9-rc1`. Application changes belong in the fork checkout at
`~/dev/random/typescript/LibreChat`. The overlay in `overlays/librechat.nix`
fetches an immutable commit from the published fork; deployment does not depend
on that local checkout or the current branch tip.

Validate and review changes in the fork before publishing its branch. Update
`revision` and the source hash in the overlay to the published commit, then run
the LibreChat package and startup checks on Darwin and Linux. Keep the npm
dependency hash when the dependency output is unchanged. A dependency update
requires a new hash and package validation. The overlay disables the generic
package updater because a release update must preserve or supersede the fork's
authentication changes.

[LibreChat fork]: https://github.com/iainlane/LibreChat
