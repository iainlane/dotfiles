# Pi

A managed Pi setup for coding, investigation and implementation planning.

Run `/login openai` to use a ChatGPT subscription, or `pi /login` for other
model providers. Use `pi mcp login <server>` for OAuth MCP servers.

Nix manages configuration and extension versions. Change shared settings here;
Pi cannot save changes over the generated files in `~/.pi/agent/`.

## Installation and temporary runs

Home Manager installs the configured executable. `nix build .#pi-configured`
builds the executable and its assets; `packages.pi` is the independent upstream
core.

Run the shared configuration without activating Home Manager:

```sh
nix run .#pi
```

The app uses shared defaults, not a host profile, and accepts native Pi CLI
arguments. Each invocation uses a private writable temporary profile.

Environment credentials are inherited. The app can reuse static API keys from
`PI_CODING_AGENT_DIR` (default: `~/.pi/agent`). Provider OAuth credentials and
MCP grants are not imported; log in within the temporary run when needed. Those
credentials remain temporary.

The app copies `models.json` and `keybindings.json` from the source profile if
present. Installed settings and package/resource lists are not imported.

OS cleanup, Nix garbage collection or reboot can invalidate the temporary
profile. Use the Home Manager installation for durable sessions and background
work.

## Everyday use

[Plan mode] develops a reviewed implementation plan before project changes.
`/plan <task>` starts the workflow; `/plan` toggles the mode.

The [session footer] shows model, context, quota and work that needs attention.
Use `/footer` to inspect details. OpenAI quota reporting requires a separate
legacy login with `/login openai-codex`.

`/subagents` manages delegated work, `/todos` manages execution tasks, and `/pr`
inspects the pull request.

`/btw <question>` opens a side conversation using the current conversation as
context. Its usage is reported separately.

`/simplify --staged` reviews staged changes. An empty staged selection does not
review another commit. Pi Pretty formats file and shell output. Pi Diff provides
expandable file changes.

[Plan mode]: ../../../pkgs/pi-planning/README.md
[session footer]: ../../../pkgs/pi-session-footer/README.md

## Permissions

Shell commands use [automatic permission review] with the same OpenAI login as
the main agent. Other tools run without permission review. A failed or
unavailable review falls back to a human prompt; a refusal blocks the command.

Nix manages `authorizerChain` and the complete `permission` policy. Runtime
settings, including YOLO and logging, remain writable.

Use `/auto-stats` to inspect reviewer state and `/permission-auto-review` to
configure the reviewer. No investigation sandbox is configured, so reviews use
the transcript without local investigation tools. Permission review is not an OS
sandbox for the main agent.

[automatic permission review]:
  https://github.com/iainlane/pi-packages/tree/codex-parity/packages/pi-permission-auto-review

## Code intelligence

Lens supplies structural code inspection and diagnostic feedback. Nix provides
grammars and helper tools. Swift parsing is unavailable on the current Node
runtime.

TypeScript uses the packaged `typescript-language-server` with a project
compiler or its packaged fallback.

MCP servers and language tools are shared with the other [AI harnesses].
Service-tier controls apply to parent requests; delegated requests use the
subagent runtime's model and thinking settings.

[AI harnesses]: ../README.md

## Maintenance

Update an upstream extension with `nix run .#update-<package>`. Automatic
permission review is an exception: update the `codex-parity` commit in
`pkgs/pi-permission-auto-review/source.json` and maintain its npm lockfile
alongside the pin. The same file pins the BYOS SDK source.

Local extension sources are under `pkgs/`.
