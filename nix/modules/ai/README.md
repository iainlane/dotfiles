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

- `gemini-cli.nix` - Uses `programs.gemini.mcp.servers`

These are the simplest integrations - no config file generation needed.

### Config file generation

Other tools expect a configuration file on disk. For these, we use
`mcp.mkConfigFile` which generates the file in the appropriate format:

- `claude-desktop.nix` - Generates JSON for Claude Desktop on Darwin
- `crush.nix` - Generates JSON for the crush config directory
- `copilot-cli.nix` - Generates JSON for GitHub Copilot CLI
- `opencode.nix` - Generates JSON for OpenCode

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

- `claude-code.nix`
- `codex.nix`
- `copilot-cli.nix`
- `crush.nix`
- `gemini-cli.nix`
- `opencode.nix`

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
