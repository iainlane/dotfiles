# AI Tools

Nix modules for AI coding assistants, all sharing a common set of [MCP
servers][mcp].

## How it works

Every tool should talk to the same MCP servers without repeating the config. We
do this by:

1. `mcp-servers.nix` evaluates the `mcp-servers-nix` module once to get a
   computed attrset of server definitions
2. Each tool module imports `mcp-servers.nix` and uses those servers

Different tools need different approaches:

### Direct server configuration

Some tools' home-manager modules accept an `mcpServers` attribute directly:

- `antigravity-cli.nix` - Uses `programs.antigravity-cli.mcpServers`

These are the simplest integrations - no config file generation needed.

### Config file generation

Other tools expect a configuration file on disk. For these, we use
`mcp.mkConfigFile` which generates the file in the appropriate format:

- `claude-desktop/` - Generates JSON for Claude Desktop on macOS and Linux. On
  Linux it also installs the application itself (from the `llm-agents` input) on
  hosts that have the desktop profile; macOS gets the app from the Homebrew cask
- `crush.nix` - Generates JSON for the crush config directory
- `copilot-cli.nix` - Generates JSON for GitHub Copilot CLI
- `opencode.nix` - Generates JSON for OpenCode
- `opencode2.nix` - Generates JSON for OpenCode 2

OpenCode 2 (`opencode2.nix`) ships as a separate `opencode2` binary but reads
the same `~/.config/opencode` as OpenCode 1, and the two config schemas are not
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
upstream home-manager module. Pinned Pi extensions are built as fixed-output Nix
derivations in `pi/extensions.nix` and surfaced as local-path packages, so
runtime package updates are not needed. `pi-mcp-adapter` reads the shared
`~/.config/mcp/mcp.json`, and auth stays interactive through `pi /login`.

The `mkConfigFile` function takes three parameters:

- `flavor` - Tool-specific schema ("claude", "codex", etc.)
- `format` - Serialisation format ("json", "toml-inline")
- `fileName` - Output filename

### Managed config files

Two tools use a system-level config file so the user-level config stays free for
interactive edits:

- `claude-code.nix` - Writes Claude Code managed settings at the OS-specific
  system path
- `codex.nix` - Writes `/etc/codex/managed_config.toml` with the shared MCP
  servers

Codex itself now reads layered config files (`~/.codex/config.toml`,
`.codex/config.toml`, `/etc/codex/config.toml`, and
`/etc/codex/managed_config.toml`), so we use the managed layer for shared
defaults rather than injecting `-c` flags on every launch.

### Binary wrapping

Most tools still need a wrapped binary so their private tool dependencies are on
`PATH`:

- `antigravity-cli.nix`
- `claude-code.nix`
- `codex.nix`
- `copilot-cli.nix`
- `crush.nix`
- `opencode.nix`
- `opencode2.nix`
- `pi.nix`

## Adding a new tool

1. Create `<tool>.nix` in this directory
2. Import `mcp-servers.nix` to get access to servers
3. Choose the integration method:
   - If the home-manager module accepts `mcpServers`, use `mcp.servers`
   - If it needs a config file, use `mcp.mkConfigFile`
   - If it needs system-managed defaults, follow the `claude-code.nix` /
     `codex.nix` pattern
4. Add the module to `default.nix`

[mcp]: https://modelcontextprotocol.io/
