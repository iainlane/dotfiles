# Configure OpenCode with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  options,
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

  hasCatppuccinOpencodeModule = options ? catppuccin && options.catppuccin ? opencode;
in {
  config =
    {
      programs.opencode = {
        enable = true;
        package = wrappedOpencode;
        enableMcpIntegration = true;
        rules = instructions.concatenated;
      };
    }
    // lib.optionalAttrs hasCatppuccinOpencodeModule {
      catppuccin.opencode.enable = true;
    };
}
