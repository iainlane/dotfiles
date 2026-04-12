# Configure OpenCode with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};

  # Wrap OpenCode to add shared tools to PATH
  wrappedOpencode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.opencode;
    binName = "opencode";
  };
in {
  config = {
    programs.opencode = {
      enable = true;
      package = wrappedOpencode;
      enableMcpIntegration = true;
      rules = instructions.concatenated;
      tui.theme = "system";
    };
  };
}
