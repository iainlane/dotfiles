# Configure Claude Code with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Wrap Claude Code to add shared tools to PATH
  wrappedClaudeCode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.claude-code;
    binName = "claude";
  };
in {
  programs.claude-code = {
    enable = true;
    package = wrappedClaudeCode;
    mcpServers = mcp.servers;
  };
}
