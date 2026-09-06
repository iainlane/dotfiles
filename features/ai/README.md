# AI Tools

Nix modules for AI coding assistants, all sharing a common set of [MCP
servers][mcp].

## How it works

Every tool should talk to the same MCP servers without repeating the config. We
do this by:

1. `mcp-servers.nix` evaluates the `mcp-servers-nix` module once to get a
   computed attrset of server definitions, per channel
2. The OS adapters pass that set to every module as the `mcp` argument.
   `mcp-server-set.nix` combines `mcp.servers` with the secret servers for the
   host and assigns the result to `dotfiles.ai.mcpServers`
3. Each harness reads `config.dotfiles.ai.mcpServers`, so a feature can add a
   server and every harness picks it up

Different tools need different approaches:

### Direct server configuration

Some tools' home-manager modules accept an `mcpServers` attribute directly:

- `antigravity-cli/` - Uses `programs.antigravity-cli.mcpServers`

These are the simplest integrations - no config file generation needed.

### Config file generation

Other tools expect a configuration file on disk. Each of these writes its own
file, reshaping the shared set into the schema the tool reads:

- `claude-desktop/` - Generates JSON for Claude Desktop on macOS and Linux. On
  Linux it also installs the application itself (from the `llm-agents` input);
  macOS gets the app from the Homebrew cask. `desktop` lists this child, so only
  GUI hosts get it
- `crush/` - Generates JSON for the crush config directory
- `copilot-cli/` - Generates JSON for GitHub Copilot CLI
- `opencode/` - Generates JSON for OpenCode
- `opencode2/` - Generates JSON for OpenCode 2

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

Pi (`pi/`) writes its configuration directly into `~/.pi/agent/` via
`home.file`, since Pi is configured through that directory rather than an
upstream home-manager module. Pinned Pi extensions are packaged under
`pkgs/<name>/` and installed as local-path packages, so Pi never downloads them
itself. Each extension is bumped by `nix run .#update-<name>`, which the
scheduled `package update` workflow runs alongside the other packages.
`pi-mcp-adapter` reads the shared `~/.config/mcp/mcp.json`, and auth stays
interactive through `pi /login`.

### Managed config files

Two tools use a system-level config file so the user-level config stays free for
interactive edits:

- `claude-code/` - Writes Claude Code managed settings at the OS-specific system
  path
- `codex/system-config.nix` - Writes `/etc/codex/config.toml` with shared
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
`declareSopsSecrets` and `secretPath`, and the module it returns declares
`dotfiles.ai.mcpServers` and defines it from the `mcp` argument plus the
credential-bearing servers for this host.

- `mcp.nix`, the `ai` feature's home-manager module, calls it with the defaults:
  it declares the sops secrets those servers need and reads each secret's
  runtime path from `config.sops.secrets.<name>.path`.
- `codex/system-config.nix` is a system module and calls it with
  `declareSopsSecrets = false` and a `secretPath` built from the user's home
  directory, because the home-manager configuration has already declared the
  same secrets and a system module cannot read where it decided to put them.

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
replaces the shared file for that harness alone. A harness with no native
output-style support also receives the default style's body as an ordinary
instruction. Claude Code's set leaves it out: Claude Code installs the styles
natively, so the body already reaches the model by that route.

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
for a tree of its own.

## Unstable home-manager modules

`unstable-hm-modules.nix` replaces `programs.antigravity-cli`,
`programs.claude-code`, `programs.codex`, `programs.mcp` and `programs.opencode`
with the copies from the unstable home-manager input, on every host with `ai`.
These tools move fast enough that the stable channel's copies lack options the
modules here set. `disabledModules` names both the single-file and the directory
form of each module, because the two channels disagree on the layout and
unmatched entries are ignored.

The replacements are imported as values and not listed as paths in `imports`. A
path in `imports` keeps the module key that `disabledModules` matches on, so
listing the paths would disable these copies as well and leave the options
undeclared.

Those modules are written against unstable's `lib.hm`. On stable hosts,
`lib/home.nix` passes home-manager a library extended with unstable's `lib.hm`.
`desktop.voxtype` also uses an unstable module and needs the same extension.

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
