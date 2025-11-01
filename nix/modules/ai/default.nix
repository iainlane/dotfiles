# Load every AI tool module so they all see the same MCP server set.
{
  imports = [
    ./mcp.nix
    ./claude-code.nix
    ./claude-desktop.nix
    ./codex.nix
    ./copilot-cli.nix
    ./crush.nix
    ./gemini-cli.nix
    ./opencode.nix
  ];
}
