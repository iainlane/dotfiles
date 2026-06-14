{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  options,
  config,
  ...
}: {
  imports = [
    (import ./mcp-server-set.nix {inherit inputs lib pkgs pkgs-unstable;})
  ];

  # Mirror the set into programs.mcp for upstream `enableMcpIntegration`
  # consumers (e.g. VS Code), which read it directly.
  config = lib.optionalAttrs (options ? programs && options.programs ? mcp) {
    programs.mcp = {
      enable = true;
      servers = config.dotfiles.ai.mcpServers;
    };
  };
}
