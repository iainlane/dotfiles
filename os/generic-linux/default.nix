{
  inputs,
  lib,
  config,
  withSystem,
  username,
  overlays,
  nixpkgsConfig,
  ...
}: hostConfig: let
  sops = import ../../lib/sops.nix {inherit inputs lib;};
  inherit (import ../../lib/features.nix {inherit lib;}) resolveFeatures;
  inherit (import ../../lib/channels.nix {inherit inputs;}) channelFor;

  homeExtraModules = [
    {
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
    }
  ];
  result = withSystem hostConfig.system (
    {
      mcpByChannel,
      pkgs,
      pkgs-stable,
      ...
    }: let
      channel = channelFor {
        inherit (hostConfig) channel;
        inherit pkgs pkgs-stable;
      };
    in {
      homeSpecialArgs = {
        mcp = mcpByChannel.${hostConfig.channel};
        pkgs-unstable = channel.unstable;
      };
      mkSystemConfig = _:
        inputs.system-manager.lib.makeSystemConfig {
          inherit overlays;
          modules =
            [
              sops.systemSopsModule
              sops.linuxSystemSopsModule
              ./system.nix
              inputs.sops-nix.nixosModules.sops
              config.flake.nix.substitutersModule
            ]
            ++ resolveFeatures {
              class = "systemManager";
              inherit hostConfig;
            }
            ++ [hostConfig.systemModule];
          specialArgs = {
            inherit
              inputs
              hostConfig
              username
              nixpkgsConfig
              ;
            mcp = mcpByChannel.${hostConfig.channel};
            pkgs-unstable = channel.unstable;
          };
        };
    }
  );
in {
  homeBaseDir = "/home";
  systemSuffix = "linux";
  extraHomeModules = homeExtraModules;
  inherit (result) homeSpecialArgs mkSystemConfig;
}
