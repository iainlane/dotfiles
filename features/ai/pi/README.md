# Pi

A managed Pi setup for coding, investigation and implementation planning. It
combines upstream extensions with focused local integration so authentication,
models, tools and session status work together.

Use `pi /login` for model authentication and `pi mcp login <server>` for OAuth
MCP servers. Nix manages configuration and extension versions. Change shared
settings here; Pi cannot save changes over the generated files in
`~/.pi/agent/`.

The default model uses `openai`. Run `/login openai` to use a ChatGPT
subscription. Pi 0.99.0 superseded `openai-codex` with this login and labelled
the old provider as legacy. The providers use different OAuth grants, so do not
rename an existing credential in `auth.json`.

## Installation and temporary runs

Home Manager installs the configured executable and recursively links its shared
resource collections. The executable uses that installation without changing
configuration at launch. `nix build .#pi-configured` builds the executable and
its assets; `packages.pi` remains the independent upstream core.

Run the shared configuration without activating Home Manager:

```sh
nix run .#pi
```

The app uses shared model, instruction, skill and MCP defaults, not a host
profile. Native CLI arguments pass through unchanged. Each invocation links the
built collections into a private writable agent directory in the OS temporary
area. Pretty, Lens and rpiv use the temporary profile. HOME stays unchanged;
unrelated XDG helper configuration remains accessible through symlinks.

Environment credentials are inherited. The app can reuse validated static
`api_key` records from the source profile, but it does not copy or link provider
OAuth records or MCP grants. Independent copies of rotating grants can diverge
after a refresh, and path aliases do not guarantee a shared credential lock. Use
native login in the app when needed; those credentials remain temporary.

`PI_CODING_AGENT_DIR` selects the source profile before launch and defaults to
`~/.pi/agent`. Optional `models.json` and `keybindings.json` are copied into
private files. Installed settings and package/resource lists are not imported.
Extension code uses the immutable `managed-extensions/` collection. The native
`extensions/` directory stays writable for permission configuration, logs and
statistics. Its managed `subagent/config.json` remains read-only. Sessions,
authentication and runtime caches use writable state outside the collections.

The launcher does not remove its temporary directory on exit, so detached
children can continue to read it. OS temporary cleanup, Nix garbage collection
or reboot can invalidate the environment. Use the Home Manager installation for
durable sessions and background work.

## Everyday use

[Plan mode] develops a reviewed implementation plan before project changes.
`/plan <task>` starts the workflow; `/plan` toggles the mode. The model can ask
questions through the general `ask_user` tool in planning and ordinary work.

The [session footer] shows model, context, quota and work that needs attention.
OpenAI quota reporting still requires legacy Codex credentials because the
`openai` grant cannot read the usage endpoint. Use `/login openai-codex` for
quota reporting. Use `/footer` to inspect details. `/subagents` manages
delegated work, `/todos` manages execution tasks, and `/pr` inspects the pull
request.

`/btw <question>` opens a side conversation using the current conversation as
context. Its questions stay within that session. Its usage is reported
separately from the main conversation.

`/simplify --staged` reviews staged changes. An empty selection does not expand
to another commit; an invalid reference reports an error. Pi Pretty formats
reads and shell output, while native search tools preserve their path and query
semantics. Pi Diff provides expandable file changes.

[Plan mode]: ../../../pkgs/pi-planning/README.md
[session footer]: ../../../pkgs/pi-session-footer/README.md

## Permissions

Shell commands use [automatic permission review]. Other tools run without
permission review. The reviewer uses `openai/codex-auto-review` with the same
OpenAI login as the main agent. A failed or unavailable review falls back to a
human prompt; a refusal blocks the command.

Nix manages `authorizerChain` and the complete `permission` policy. Home Manager
activation merges those settings into a writable config file and preserves other
fields, including runtime YOLO and logging toggles. Existing invalid JSON is
left untouched and stops activation. The app initialises the same policy in
private writable state. Temporary runs require their own OpenAI login for
automatic review because provider OAuth credentials are not imported.

Use `/auto-stats` to inspect reviewer state and `/permission-auto-review` to
configure the reviewer. Investigation requires a separately configured sandbox
provider. This setup does not enable a provider, so the reviewer uses transcript
evidence without investigation tools. Permission review is not an OS sandbox for
the main agent.

Statistics start new totals in SQLite. Older journals and session metrics are
not imported or removed.

[automatic permission review]:
  https://github.com/iainlane/pi-packages/tree/codex-parity/packages/pi-permission-auto-review

## Code intelligence

Lens supplies structural code inspection and diagnostic feedback. Grammars and
helper tools are provided by Nix, so ordinary use does not need to install them
into the immutable package directory. Swift parsing remains unavailable on the
current Node runtime because of the upstream runtime restriction.

TypeScript uses the packaged `typescript-language-server`, which can use a
project compiler or its packaged fallback. This explicitly selects the classic
language-server implementation instead of Lens's automatic native TypeScript
server selection.

MCP servers and language tools are shared with the other [AI harnesses].
Service-tier controls apply to parent requests; delegated requests use the
subagent runtime's model and thinking settings.

[AI harnesses]: ../README.md

## Maintenance

Update an upstream extension with `nix run .#update-<package>`. Automatic
permission review is an exception: `pkgs/pi-permission-auto-review/source.json`
pins the `codex-parity` branch to a commit, and its npm lockfile is maintained
alongside that pin. The same file pins the BYOS SDK source. Nix packs its SDK
subdirectory for npm and includes it with the extension; no local checkout is
needed. The npm lockfile resolves workspace catalogue versions and declares Pi's
runtime modules as peers.

The startup check uses scripted models in the native Pi runtime to test shell
allows, shell denials, direct writes, unavailable investigation and statistics
across sessions. These checks do not establish live reviewer judgement or
sandbox isolation.

Local extension sources are under `pkgs/`.

`bundle.nix` constructs the executable, resource collections and configuration
from explicit inputs. Home Manager supplies merged host settings; the flake app
supplies shared defaults. `render-files.nix` uses the pinned Home Manager file
renderer and encapsulates its internal `home-files` output. The renderer
excludes the configured executable and does not evaluate a host profile.
