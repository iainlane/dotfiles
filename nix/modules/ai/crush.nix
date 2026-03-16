# Configure Crush CLI with the shared MCP servers and LSP.
{
  pkgs,
  config,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Crush expects its MCP servers and LSP config inside crush.json
  crushConfig = pkgs.writeText "crush.json" (
    builtins.toJSON {
      "$schema" = "https://charm.land/crush.json";
      mcp = config.programs.mcp.servers;
    }
  );

  # Wrap Crush to add shared tools to PATH
  wrappedCrush = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.crush;
    binName = "crush";
  };
in {
  home.packages = [wrappedCrush];

  # Point Crush at the generated config file.
  xdg.configFile."crush/crush.json".source = crushConfig;
}
