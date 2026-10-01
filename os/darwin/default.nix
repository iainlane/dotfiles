{
  inputs,
  lib,
  config,
  withSystem,
  username,
  featureResolver,
  ...
}: hostConfig: let
  sops = import ../../lib/sops.nix {inherit inputs lib;};
  home = import ../../lib/home.nix {inherit inputs lib featureResolver;};
  inherit (featureResolver) resolveFeatures;
  inherit (import ../../lib/channels.nix {inherit inputs;}) channelFor;
  inherit (import ../../lib/system.nix {inherit inputs;}) mkSystemSpecialArgs;
  inherit (config.flake) modelCatalog;

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
      homeSpecialArgs = home.mkHomeSpecialArgs {
        inherit hostConfig mcpByChannel modelCatalog pkgs pkgs-stable;
      };
      mkSystemConfig = homeDefinition:
        inputs.nix-darwin.lib.darwinSystem {
          inherit (hostConfig) system;
          pkgs = channel.primary;
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
              channel.home-manager.darwinModules.home-manager
              (home.mkEmbeddedHomeManager {inherit username homeDefinition;})
            ];
          specialArgs = mkSystemSpecialArgs {
            inherit hostConfig username mcpByChannel channel modelCatalog;
          };
        };
    }
  );
in {
  inherit (result) homeSpecialArgs mkSystemConfig;
}
