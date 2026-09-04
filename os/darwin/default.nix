{
  inputs,
  config,
  withSystem,
  helpers,
  username,
  ...
}: hostConfig: let
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
              helpers.systemSopsModule
              ./system.nix
              config.flake.nix.substitutersModule
              inputs.determinate.darwinModules.default
              inputs.sops-nix.darwinModules.sops
            ]
            ++ helpers.resolveFeatures {
              class = "darwin";
              inherit hostConfig;
            }
            ++ [
              hostConfig.systemModule
              inputs.home-manager.darwinModules.home-manager
              (helpers.mkEmbeddedHomeManager {inherit username homeDefinition;})
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
