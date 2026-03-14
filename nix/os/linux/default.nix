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
  result = withSystem hostConfig.system (
    {pkgs, ...}: {
      homeSpecialArgs = {
        pkgs-unstable = pkgs;
      };
      systemConfig = inputs.system-manager.lib.makeSystemConfig {
        inherit overlays;
        modules =
          [
            ./system.nix
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
  extraHomeModules = [
    {
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
    }
  ];
  inherit (result) homeSpecialArgs systemConfig;
}
