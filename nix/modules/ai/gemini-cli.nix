# Configure the Gemini CLI home-manager module with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Wrap Gemini CLI to add shared tools to PATH
  wrappedGemini = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.gemini-cli;
    binName = "gemini";
  };
in {
  programs.gemini-cli = {
    enable = true;
    package = wrappedGemini;
    # The module exposes settings.mcpServers; feed in the shared list.
    settings.mcpServers = mcp.servers;
  };
}
