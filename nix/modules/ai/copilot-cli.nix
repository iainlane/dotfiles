# Configure GitHub Copilot CLI with the shared MCP servers and instructions.
#
# Note: upstream global instructions support
# (~/.copilot/copilot-instructions.md) is documented but buggy. We place the
# file anyway as best-effort.
{
  pkgs,
  config,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};

  # Copilot CLI reads servers from a JSON file; generate it from the shared set.
  copilotMcpConfig = pkgs.writeText "mcp-config.json" (
    builtins.toJSON {
      inherit (config.programs.mcp) servers;
    }
  );

  # Wrap Copilot CLI to add shared tools to PATH
  wrappedCopilot = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.copilot-cli;
    binName = "copilot";
  };
in {
  home.packages = [wrappedCopilot];

  home.file.".copilot/copilot-instructions.md".text = instructions.concatenated;

  # Point Copilot CLI at the generated config file.
  xdg.configFile."mcp-config.json".source = copilotMcpConfig;
}
