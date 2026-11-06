{modelCatalog}: {
  inputs,
  pkgs,
  flakeContext,
  ...
}: let
  bundle = import ./bundle.nix {
    inherit inputs pkgs modelCatalog;
    mcp = flakeContext.mcpByChannel.unstable;
    mcpServers = flakeContext.mcpRegistry.servers;
  };
in {
  apps.pi = {
    type = "app";
    program = pkgs.lib.getExe bundle.app;
    meta.description = "Run the configured Pi in a private temporary profile";
  };
  packages.pi-configured = bundle.package;
}
