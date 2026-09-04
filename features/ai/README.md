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
