# Configure OpenCode with the shared MCP servers.
{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};
  skills = import ./skills.nix {inherit lib;};

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

      context = instructions.concatenated;
      enableMcpIntegration = true;

      settings = {
        # Updates come from Nix, not opencode's self-updater.
        autoupdate = false;
      };

      tui.theme = "system";

      # Shared skills from ./skills/.
      inherit skills;
    };
  };
}
