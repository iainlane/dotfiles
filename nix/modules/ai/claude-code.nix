# Configure Claude Code with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
in {
  programs.claude-code = {
    enable = true;
    package = inputs.nix-ai-tools.packages.${system}.claude-code;
    mcpServers = mcp.servers;
  };
}
