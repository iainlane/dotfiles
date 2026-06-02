{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  options,
  config,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
in {
  options.dotfiles.ai.mcpServers = mcp.mcpServersOption;

  config = lib.mkMerge [
    {dotfiles.ai.mcpServers = mcp.servers;}

    # Mirror the set into programs.mcp for upstream `enableMcpIntegration`
    # consumers (e.g. VS Code), which read it directly.
    (lib.optionalAttrs (options ? programs && options.programs ? mcp) {
      programs.mcp = {
        enable = true;
        servers = config.dotfiles.ai.mcpServers;
      };
    })
  ];
}
