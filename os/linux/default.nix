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
              helpers.systemSopsModule
              helpers.linuxSystemSopsModule
              ./system.nix
              inputs.sops-nix.nixosModules.sops
              config.flake.nix.substitutersModule
            ]
            ++ helpers.mkModules {
              moduleType = "systemManagerModule";
              inherit hostConfig;
              inherit (config.flake) profiles modules;
            }
            ++ lib.optional (hostConfig.systemModule != null) hostConfig.systemModule;
          specialArgs = {
            inherit
              inputs
              hostname
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
