# Pi

A managed Pi setup for coding, investigation and implementation planning. It
combines upstream extensions with focused local integration so authentication,
models, tools and session status work together.

Use `pi /login` for model authentication and `pi mcp login <server>` for OAuth
MCP servers. Nix manages configuration and extension versions. Change shared
settings here; Pi cannot save changes over the generated files in
`~/.pi/agent/`.

## Everyday use

[Plan mode] develops a reviewed implementation plan before project changes.
`/plan <task>` starts the workflow; `/plan` toggles the mode. The model can ask
questions through the general `ask_user` tool in planning and ordinary work.

The [session footer] shows model, context, quota and work that needs attention.
Use `/footer` to inspect details. `/subagents` manages delegated work, `/todos`
manages execution tasks, and `/pr` inspects the pull request.

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
permission review. The reviewer uses `openai-codex/codex-auto-review` with the
existing Codex login. A failed or unavailable review falls back to a human
prompt; a refusal blocks the command.

Nix manages `authorizerChain` and the complete `permission` policy. Activation
merges those settings into a writable config file and preserves other fields,
including runtime YOLO and logging toggles. Existing invalid JSON is left
untouched and stops activation.

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
