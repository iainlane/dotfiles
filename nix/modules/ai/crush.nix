# Configure Crush CLI with the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Crush expects its MCP servers inside crush.json; build the file here.
  crushConfig = pkgs.writeText "crush.json" (
    builtins.toJSON {
      "$schema" = "https://charm.land/crush.json";
      mcp = mcp.servers;
    }
  );
in {
  home.packages = [inputs.nix-ai-tools.packages.${system}.crush];

  # Point Crush at the generated config file.
  xdg.dataFile."crush/crush.json".source = crushConfig;
}
