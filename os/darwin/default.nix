{
  inputs,
  lib,
  config,
  withSystem,
  helpers,
  username,
  ...
}: hostname: hostConfig: let
  result = withSystem hostConfig.system (
    args: let
      inherit (args.config._module.args) pkgs pkgs-stable;
      homeSpecialArgs = {
        pkgs-unstable = pkgs;
      };
      homeConfig = helpers.mkHomeConfiguration {
        inherit
          hostConfig
          hostname
          username
          ;
        inherit (hostConfig) system;
        inherit (config.flake) profiles modules;
        extraSpecialArgs = homeSpecialArgs;
      };
    in {
      inherit homeSpecialArgs;
      systemConfig = inputs.nix-darwin.lib.darwinSystem {
        inherit (hostConfig) system;
        inherit pkgs;
        modules =
          [
            helpers.mkSystemSopsModule
            ./system.nix
            config.flake.nix.substitutersModule
            inputs.determinate.darwinModules.default
            inputs.sops-nix.darwinModules.sops
          ]
          ++ helpers.mkModules {
            moduleType = "systemManagerModule";
            inherit hostConfig;
            inherit (config.flake) profiles modules;
          }
          ++ lib.optional (hostConfig.systemModule != null) hostConfig.systemModule
          ++ [
            inputs.home-manager.darwinModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.${username}.imports = homeConfig.modules;
                inherit (homeConfig) extraSpecialArgs;
              };
            }
          ];
        specialArgs = {
          inherit
            inputs
            hostname
            hostConfig
            pkgs-stable
            username
            ;
          pkgs-unstable = pkgs;
        };
      };
    }
  );
in {
  homeBaseDir = "/Users";
  systemSuffix = "darwin";
  inherit (result) homeSpecialArgs systemConfig;
}
