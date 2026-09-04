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
      ...
    }: {
      homeSpecialArgs = {
        mcp = mcpByChannel.${hostConfig.channel};
        pkgs-unstable = pkgs;
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
            pkgs-unstable = pkgs;
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
