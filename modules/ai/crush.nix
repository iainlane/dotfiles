# Configure Crush CLI with the shared MCP servers, LSP and instructions.
{
  pkgs,
  pkgs-unstable,
  config,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};

  # Crush expects its MCP servers and LSP config inside crush.json. Global
  # instructions are loaded via options.context_paths.
  crushConfig = pkgs.writeText "crush.json" (
    builtins.toJSON {
      "$schema" = "https://charm.land/crush.json";
      mcp = config.dotfiles.ai.mcpServers;
      options.context_paths = ["~/.config/crush/AGENTS.md"];
    }
  );

  # Wrap Crush to add shared tools to PATH
  wrappedCrush = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.crush;
    binName = "crush";
  };
in {
  home.packages = [wrappedCrush];

  xdg.configFile = {
    # Point Crush at the generated config file.
    "crush/crush.json".source = crushConfig;

    # Shared instructions for Crush to load via context_paths.
    "crush/AGENTS.md".text = instructions.concatenated;
  };
}
