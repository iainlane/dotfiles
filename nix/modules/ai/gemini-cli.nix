# Configure the Gemini CLI home-manager module with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
in {
  programs.gemini-cli = {
    enable = true;
    package = inputs.nix-ai-tools.packages.${system}.gemini-cli;
    # The module exposes settings.mcpServers; feed in the shared list.
    settings.mcpServers = mcp.servers;
  };
}
