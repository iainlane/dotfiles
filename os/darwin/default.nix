{
  inputs,
  lib,
  config,
  withSystem,
  username,
  ...
}: hostConfig: let
  sops = import ../../lib/sops.nix {inherit inputs lib;};
  home = import ../../lib/home.nix {inherit inputs lib;};
  inherit (import ../../lib/features.nix {inherit lib;}) resolveFeatures;

  result = withSystem hostConfig.system (
    args: let
      inherit (args.config._module.args) mcpByChannel pkgs pkgs-stable;
      homeSpecialArgs = {
        mcp = mcpByChannel.${hostConfig.channel};
        pkgs-unstable = pkgs;
      };
    in {
      inherit homeSpecialArgs;
      mkSystemConfig = homeDefinition:
        inputs.nix-darwin.lib.darwinSystem {
          inherit (hostConfig) system;
          inherit pkgs;
          modules =
            [
              sops.systemSopsModule
              ./system.nix
              config.flake.nix.substitutersModule
              inputs.determinate.darwinModules.default
              inputs.sops-nix.darwinModules.sops
            ]
            ++ resolveFeatures {
              class = "darwin";
              inherit hostConfig;
            }
            ++ [
              hostConfig.systemModule
              inputs.home-manager.darwinModules.home-manager
              (home.mkEmbeddedHomeManager {inherit username homeDefinition;})
            ];
          specialArgs = {
            inherit
              inputs
              hostConfig
              pkgs-stable
              username
              ;
            mcp = mcpByChannel.${hostConfig.channel};
            pkgs-unstable = pkgs;
          };
        };
    }
  );
in {
  homeBaseDir = "/Users";
  systemSuffix = "darwin";
  inherit (result) homeSpecialArgs mkSystemConfig;
}
