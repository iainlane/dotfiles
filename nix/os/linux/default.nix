{
  inputs,
  lib,
  config,
  withSystem,
  helpers,
  username,
  overlays,
  nixpkgsConfig,
}: hostname: hostConfig: let
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
    {pkgs, ...}: {
      homeSpecialArgs = {
        pkgs-unstable = pkgs;
      };
      systemConfig = inputs.system-manager.lib.makeSystemConfig {
        inherit overlays;
        modules =
          [
            helpers.mkSystemSopsModule
            ./system.nix
            inputs.sops-nix.nixosModules.sops
            config.flake.nix.substitutersModule
          ]
          ++ helpers.mkModules {
            moduleType = "systemManagerModule";
            inherit hostConfig;
            inherit (config.flake) profiles;
          }
          ++ lib.optional (hostConfig.systemModule != null) hostConfig.systemModule;
        extraSpecialArgs = {
          inherit
            inputs
            hostname
            hostConfig
            username
            nixpkgsConfig
            ;
        };
      };
    }
  );
in {
  homeBaseDir = "/home";
  systemSuffix = "linux";
  extraHomeModules = homeExtraModules;
  inherit (result) homeSpecialArgs systemConfig;
}
