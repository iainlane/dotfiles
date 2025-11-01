# AI Tool MCP Server Configuration

This directory contains Nix modules for AI coding assistants, all
configured to use a shared set of [Model Context Protocol (MCP)][mcp]
servers.

## Pattern

The key insight is that we want every AI tool to talk to the same MCP
servers without repeating the configuration. We achieve this by:

1. Single evaluation in `mcp-servers.nix`: We evaluate the
   `mcp-servers-nix` module once to get a computed attribute set of
   server definitions
1. Shared imports: Each tool module imports `mcp-servers.nix` and
   consumes the servers

Different tools need different approaches:

### Direct server configuration

Some tools' home-manager modules accept an `mcpServers` attribute
directly:

- `claude-code.nix` - Passes `mcp.servers` to
  `programs.claude-code.mcpServers`
- `gemini-cli.nix` - Uses `programs.gemini.mcp.servers`

These are the simplest integrations - no config file generation needed.

### Config file generation

Other tools expect a configuration file on disk. For these, we use
`mcp.mkConfigFile` which generates the file in the appropriate format:

- `claude-desktop.nix` - Generates JSON for
  `~/Library/Application Support/Claude/`
- `crush.nix` - Generates JSON for the crush config directory
- `copilot-cli.nix` - Generates JSON for GitHub Copilot CLI
- `opencode.nix` - Generates JSON for OpenCode

The `mkConfigFile` function takes three parameters:

- `flavor` - Tool-specific schema ("claude", "codex", etc.)
- `format` - Serialisation format ("json", "toml-inline")
- `fileName` - Output filename

### Binary wrapping

One tool needs special handling:

- `codex.nix` - Wraps the binary to inject inline TOML config via `-c`
  flag

This is necessary because Codex requires the configuration as a
command-line argument rather than reading from a file.

## Adding a new tool

1. Create `<tool>.nix` in this directory
1. Import `mcp-servers.nix` to get access to servers
1. Choose the appropriate integration method:
   - If the tool's home-manager module accepts `mcpServers`, use
     `mcp.servers` directly
   - If it needs a config file, use `mcp.mkConfigFile` with the
     appropriate flavor and format
   - If it needs special handling, follow the `codex.nix` pattern
1. Add the module to `default.nix`

[mcp]: https://modelcontextprotocol.io/
