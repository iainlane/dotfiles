# AI Tools

Nix modules for AI coding assistants, all sharing a common set of [MCP
servers][mcp].

## How it works

Every tool should talk to the same MCP servers without repeating the config. We
do this by:

1. `mcp-server-definitions.nix` evaluates the `mcp-servers-nix` module once per
   system to get a computed attrset of server definitions, and `mcp-servers.nix`
   wraps that set with the helpers and tools of each channel
2. The OS adapters pass that set to every module as the `mcp` argument.
   `mcp-server-set.nix` combines `mcp.servers` with the secret servers for the
   host and assigns the result to `dotfiles.ai.mcpServers`
3. Each harness reads `config.dotfiles.ai.mcpServers`, so a feature can add a
   server and every harness picks it up

Different tools need different approaches:

### Direct server configuration

Some tools' home-manager modules accept an `mcpServers` attribute directly:

- `antigravity-cli/`: uses `programs.antigravity-cli.mcpServers`

These are the simplest integrations: no configuration file has to be generated.

### Config file generation

Other tools expect a configuration file on disk. Each of these writes its own
file, reshaping the shared set into the schema that the tool reads:

- `claude-desktop/`: generates JSON for Claude Desktop on macOS and Linux. On
  Linux it also installs the application itself (from the `llm-agents` input);
  macOS gets the app from the Homebrew cask. `desktop` lists this child, so only
  GUI hosts get it
- `crush/`: generates JSON for the crush config directory
- `copilot-cli/`: generates JSON for GitHub Copilot CLI
- `opencode/`: generates JSON for OpenCode
- `opencode2/`: generates JSON for OpenCode 2

OpenCode 2 (`opencode2/`) ships as a separate `opencode2` binary but reads the
same `~/.config/opencode` as OpenCode 1, and the two config schemas are not
interchangeable: OpenCode 2 nests MCP servers under `mcp.servers`, replaces
`enabled` with `disabled`, and moves the theme and keybindings into a `cli.json`
of their own. So the wrapper sets `OPENCODE_CONFIG_DIR` to `~/.config/opencode2`
and the module owns that directory instead. Credentials live under
`~/.local/share/opencode` either way, so logging in once covers both versions.
`cli.json` is left unmanaged, because OpenCode 2 rewrites it whenever the theme
or a setting changes in the TUI. A `tui.json` is written instead: OpenCode 2
reads that once, while `cli.json` is still absent, and translates it, which is
enough to pick the theme on a new machine without taking the file over.

Pi reads its configuration from `~/.pi/agent/`, and no upstream Home Manager
module writes that directory, so `pi/` writes it with `home.file`. Pinned Pi
extensions are packaged under `pkgs/<name>/` and installed as local-path
packages, so Pi never downloads them itself. Each extension is bumped by
`nix run .#update-<name>`, which the scheduled `package update` workflow runs
alongside the other packages. Pi's built-in MCP support reads
`~/.pi/agent/mcp.json`, which `pi/` generates from the shared MCP server set.
The file is read-only, so changes that `/mcp` would save there have to be made
in Nix instead. Auth stays interactive through `pi /login`, and OAuth MCP
servers sign in with `pi mcp login <server>`.

### Managed config files

Two tools use a system-level config file so the user-level config stays free for
interactive edits:

- `claude-code/`: writes Claude Code managed settings at the OS-specific system
  path
- `codex/system-config.nix`: writes `/etc/codex/config.toml` with shared
  defaults and MCP servers

Codex itself reads layered config files (`/etc/codex/config.toml`,
`~/.codex/config.toml`, and `.codex/config.toml`). The system layer owns shared
defaults without enforcing them, so isolated instances and interactive user
configuration can override them. The legacy `managed_config.toml` layer is for
enforced policy and takes precedence over instance configuration.

### Binary wrapping

Most tools still need a wrapped binary so their private tool dependencies are on
`PATH`:

- `antigravity-cli/`
- `claude-code/`
- `codex/`
- `copilot-cli/`
- `crush/`
- `opencode/`
- `opencode2/`
- `pi/`

## The shared server set

`mcp-server-set.nix` is a function that returns a module, so the same servers
can be declared in two module systems from one file. It takes
`declareSopsSecrets` and `secretPath`, and the module that it returns declares
`dotfiles.ai.mcpServers` and defines it from the `mcp` argument plus the
credential-bearing servers for this host.

- `mcp.nix`, the `ai` feature's home-manager module, calls it with the defaults:
  it declares the sops secrets for those servers and reads each secret's runtime
  path from `config.sops.secrets.<name>.path`.
- `codex/system-config.nix` is a system module and calls it with
  `declareSopsSecrets = false` and a `secretPath` built from the user's home
  directory, because the home-manager configuration has already declared the
  same secrets and a system module cannot read where it decided to put them.

`cloudflare-mcp/` adds two more servers to the set: Cloudflare's account server
and its documentation server. Cloudflare is personal infrastructure, so `ai`
does not include this child, and `home` includes it on hosts that have `ai`.
Both the Home Manager and the system level read the server set, so the same
module is registered for each.

## Pooling Claude accounts

`claude-code/teamclaude/` runs Claude Code through [TeamClaude][teamclaude], a
local proxy for several Claude subscription accounts. The proxy sends each
request with the token of an account that has quota left. When an account
reaches its limit, the proxy sends the request again with another account's
token. `ai` does not include this child. `home`, the personal machines' feature,
includes it on hosts that have `ai`.

The child replaces the `claude` binary with a launcher. When the proxy is
running, the launcher sets the environment variables that `teamclaude env`
prints and then runs Claude Code. Otherwise the launcher runs Claude Code
unchanged, and Claude Code uses its own login.

The proxy runs as a user service under systemd or launchd. TeamClaude's server
exits with an error when its config lists no accounts, so the service runs the
server only once the config lists an account. The service manager watches the
config file, so the first `teamclaude login` starts the server.

[teamclaude]: https://github.com/KarpelesLab/teamclaude

## Instructions, output styles and skills

`skills.nix` publishes three values through `_module.args`, beside `mcp`: the
shared instruction set as `instructions`, the parsed output styles as
`outputStyles`, and the function that builds a skill directory as `skillTree`.
No harness module opens the source files itself. Only home-manager modules
receive these arguments, which is why `claude-code/managed-settings-common.nix`,
a system module, imports `output-styles.nix` directly. Harness modules read the
shared skill definitions from `config.dotfiles.ai.skills`.

`agent-instructions.nix` reads every `.md` file directly under `instructions/`
and returns them two ways: as `{ stem = content; }` for harnesses that accept
separate rule files, and as one string with `AGENTS.md` first and the remaining
stems in lexicographic order for harnesses that want a single blob. A harness
with instructions of its own gets a named set instead: `harnesses.claudeCode`
merges `instructions/claude-code/` over the shared files, so reusing a stem
replaces the shared file for that harness alone. Every set also includes the
default style's body as an ordinary instruction. A harness with no native
output-style support has no other way to receive it, and Claude Code receives it
twice on purpose: the output style reaches the main agent, and the rule file
reaches subagents, which run their own system prompt and are given no output
style.

`output-styles.nix` parses each `.md` file under `output-style/` into its
frontmatter `name` and `description` and the body that follows, and names
`plain-technical-prose` as the default. To add a style, drop a file in the
directory.

`skills.nix` assembles `dotfiles.ai.skills` from the directories under
`skills/`, from skills that arrive as flake inputs, and from one generated skill
per output style, so the user can ask any harness mid-session to adopt a style
by invoking the skill named after it. The `skillTree` argument merges a set of
skills into one directory and fails the build when two skills share a name and
differ. The shared tree is linked into `~/.agents/skills`, the harness-neutral
location; a harness that reads only its own directory calls `skillTree` again
for a tree of its own. That call is also where a harness leaves out unwanted
skills: `skillTree` takes an `excludes` list of names, removes them after the
merge, and fails the build for a name that matches nothing. Claude Code exposes
this as `dotfiles.claudeCode.excludeSkills`, beside `excludeMcpServers`.

## Herdr

`herdr/` installs [Herdr][herdr], a terminal workspace manager for coding
agents, from the `llm-agents` input. Home Manager writes `config.toml` through
the unstable `programs.herdr` module, and the generation fails to build when
`herdr config check` rejects the file. Herdr would otherwise ignore the whole
file and start with its defaults.

[herdr]: https://herdr.dev

### The server

A user service runs `herdr server`: `herdr.service` under systemd on Linux, and
a launchd agent on macOS. It starts with the user manager or at login. The
systemd unit sets `X-SwitchMethod=keep-old`, so a switch never restarts a
running server and the processes in its panes. To run a new Herdr version, run
`systemctl --user restart herdr`, which ends every pane's processes.

A `herdr` client starts a server of its own when none is running. When that
server has the socket, the service skips its start. To move to the service,
detach the clients, run `herdr server stop`, and start the service.

A server that starts before the desktop session imports its display variables
gives its panes no display. On Linux, zsh in a Herdr pane without a display
copies `DISPLAY`, `WAYLAND_DISPLAY` and the related variables from the user
manager.

### Plugins

`dotfiles.herdr.plugins` lists the plugin packages to link from the Nix store.
Each package specifies the plugin's directory in `passthru.pluginRoot`.
Activation links and enables every listed plugin, then removes the plugins
linked from the Nix store that the list no longer contains. Plugins linked from
elsewhere are left alone.

The default list has four plugins, packaged under `pkgs/`:

- [Context Bar][ctx-bar] draws a bar under each agent in the sidebar. Its colour
  shows how much of the context window the session uses.
- [Model Display][disp-model] shows each agent's model and reasoning effort. A
  patch keeps the agent's plain name in the sidebar, and the sidebar rows place
  the model and effort after it.
- [Annotate][annotate] collects comments on terminal selections and opens
  Markdown documents, folders and agent replies for review. Its helper builds
  from source, and document review uses `plannotator-tui` from `llm-agents`.
- [Annotate Links][annotate-links] opens Ctrl-clicked `file://` links ending in
  `.md`, `.markdown` or `.mdx` in Annotate instead of Herdr's normal file
  opener.

The Context Bar and Model Display manifests use Python from the Nix store.
Annotate's package includes both executable paths before activation, so linking
the plugin does not download binaries. The TUI is also on PATH for standalone
reviews with `plannotator-tui <file-or-folder>`.

Annotate uses these bindings after Herdr's prefix, which defaults to Ctrl+B:

| Key       | Action                                                                  |
| --------- | ----------------------------------------------------------------------- |
| `a`       | Comment on selected terminal text; Ctrl+S saves the comment             |
| `Shift+A` | Copy annotations as feedback                                            |
| `Ctrl+A`  | Copy and archive annotations                                            |
| `Ctrl+V`  | Paste feedback into the agent's prompt without submitting, then archive |
| `Ctrl+S`  | Submit feedback to the agent, then archive                              |
| `m`       | Manage annotations                                                      |
| `o`       | Review documents in the focused pane's folder                           |
| `Shift+O` | Choose a recent agent reply to review                                   |
| `Ctrl+O`  | Review the newest agent reply                                           |

Feedback becomes a message to the agent; sending feedback does not itself edit
the reviewed file. Annotations and feedback history persist outside the Nix
store. Reload changed bindings with `herdr server reload-config`.

Herdr runs a plugin's startup command only when the server starts. After an
update, Context Bar's daemon keeps running from the old store path until the
server restarts.

[ctx-bar]: https://github.com/pdalinis/herdr-ctx-bar
[disp-model]: https://github.com/pdalinis/herdr-disp-model
[annotate]: https://github.com/plannotator/herdr-annotate
[annotate-links]: https://github.com/plannotator/herdr-annotate/tree/main/links

### Agent integrations

Herdr learns each agent's session from a hook, and Context Bar reads that
session's transcript. Herdr's package contains a hook for each agent that Herdr
supports. The feature installs the hooks for each harness on the host, so
`herdr integration install` is not needed:

- Claude Code and Codex run Herdr's hook and the Model Display hooks from their
  system configuration. `dotfiles.claudeCode.managedSettings` and
  `dotfiles.codex.hooks` concatenate the hooks of each event, so the prose-lint
  hooks remain. Herdr's settings show an integration as installed only when the
  hook script is in the agent's configuration directory, so Home Manager links a
  copy there as well.
- Pi loads Herdr's extension and the Model Display adapter from
  `~/.pi/agent/extensions`.
- OpenCode loads Herdr's plugin from `~/.config/opencode/plugins`, and its TUI
  loads Herdr's session plugin through `tui.json`.
- OpenCode 2 lists its TUI plugins in `cli.json`, which OpenCode 2 rewrites
  itself, so Nix cannot add Herdr's plugin to that file. The `opencode2` wrapper
  passes `dotfiles.opencode2.cliConfig` in `OPENCODE_CLI_CONFIG_CONTENT`
  instead, and OpenCode 2 merges it over `cli.json`. The Herdr feature lists its
  plugin there. A list in that variable replaces the list in `cli.json`, so
  OpenCode 2 ignores any plugins that `cli.json` lists.

## Unstable home-manager modules

`unstable-hm-modules.nix` replaces `programs.antigravity-cli`,
`programs.claude-code`, `programs.codex`, `programs.mcp` and `programs.opencode`
with the copies from the unstable home-manager input, on every host with `ai`.
These tools move fast enough that the stable channel's copies lack options the
modules here set. The stable channel has no `programs.herdr` module, so the file
imports that module from unstable as well. `disabledModules` names both the
single-file and the directory form of each module, because the two channels
disagree on the layout and unmatched entries are ignored.

The replacements are imported as values and not listed as paths in `imports`. A
path in `imports` keeps the module key that `disabledModules` matches on, so
listing the paths would disable these copies as well and leave the options
undeclared.

Those modules are written against unstable's `lib.hm`. On stable hosts,
`lib/home.nix` passes home-manager a library extended with unstable's `lib.hm`.
`desktop.voxtype` also uses an unstable module and needs the same extension.

## Prose linting

`prose-lint.nix` installs `prose-lint`, [Vale][vale] and the Vale language
server for every harness, and writes the Vale and `prose-lint` configuration
that the package ships.

Rules come in two tiers. Portable rules encode the plain technical prose style
and apply wherever the tool runs. House rules are local preferences that another
project has no reason to share, so they report as errors only in a repository
owned by one of the accounts in `dotfiles.ai.proseLint.owners`, and as warnings
anywhere else. Ownership is read from the repository's git remotes.

A rule can be lowered for a single repository: the CLI records the override
together with a reason and keeps it out of the commit. The package's own
documentation has the commands. Claude Code runs the tool from hooks in its
managed settings; this repository lints its own text and commit messages through
`flake/parts/git-hooks.nix`.

[vale]: https://vale.sh/

## Adding a new tool

1. Create `<tool>/` in this directory, with a `default.nix` registering
   `flake.features.ai.provides.<tool>` and the class modules beside it
2. Read the servers from `config.dotfiles.ai.mcpServers`
3. Choose the integration method:
   - If the home-manager module accepts `mcpServers`, hand it the set
   - If it needs a config file, generate one with `pkgs.formats`
   - If it needs system-managed defaults, follow the `claude-code/` or `codex/`
     pattern
4. Import the directory from `default.nix` and list the child in
   `flake.features.ai.includes`

[mcp]: https://modelcontextprotocol.io/
