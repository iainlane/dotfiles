# Load every AI tool module so they all see the same MCP server set.
{mkProfileImports, ...}: {
  imports = mkProfileImports ./. [
    ./mcp.nix
    ./claude-code.nix
    ./codex.nix
    ./copilot-cli.nix
    ./crush.nix
    ./gemini-cli.nix
    ./opencode.nix
  ];
}
