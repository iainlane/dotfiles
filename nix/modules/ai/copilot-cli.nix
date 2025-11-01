# Configure GitHub Copilot CLI with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Copilot CLI reads servers from a JSON file; generate it from the shared set.
  copilotMcpConfig = pkgs.writeText "mcp-config.json" (
    builtins.toJSON {
      inherit (mcp) servers;
    }
  );

  # Wrap Copilot CLI to add shared tools to PATH
  wrappedCopilot = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.copilot-cli;
    binName = "copilot";
  };
in {
  home.packages = [wrappedCopilot];

  # Point Copilot CLI at the generated config file.
  xdg.configFile."mcp-config.json".source = copilotMcpConfig;
}
