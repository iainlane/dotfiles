{
  inputs,
  lib,
  config,
  withSystem,
  flakeContexts,
  username,
  featureResolver,
  hostInventories,
  ...
}: hostConfig: let
  sops = import ../../lib/sops.nix {inherit inputs lib;};
  home = import ../../lib/home.nix {inherit inputs lib featureResolver;};
  inherit (featureResolver) resolveFeatures;
  inherit (import ../../lib/channels.nix {inherit inputs;}) channelFor;
  inherit (import ../../lib/system.nix {inherit inputs;}) mkSystemSpecialArgs;
  inherit (config.dotfiles) modelCatalog;

  result = withSystem hostConfig.system (
    {
      flakeContext,
      pkgs,
      pkgs-stable,
      ...
    }: let
      inherit (flakeContext) mcpByChannel;
      channel = channelFor {
        inherit (hostConfig) channel;
        inherit pkgs pkgs-stable;
      };
    in {
      homeSpecialArgs = home.mkHomeSpecialArgs {
        inherit hostConfig mcpByChannel modelCatalog pkgs pkgs-stable flakeContexts;
        hostInventory = hostInventories.${hostConfig.name};
      };
      mkSystemConfig = homeDefinition:
        inputs.nix-darwin.lib.darwinSystem {
          inherit (hostConfig) system;
          pkgs = channel.primary;
          modules =
            [
              sops.systemSopsModule
              ./system.nix
              config.dotfiles.nix.substitutersModule
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
            inherit hostConfig username mcpByChannel channel modelCatalog flakeContexts;
            hostInventory = hostInventories.${hostConfig.name};
          };
        };
    }
  );
in {
  toplevel = configuration: configuration.config.system.build.toplevel;
  systemProfile = deployLib: configuration: {
    user = "root";
    path = deployLib.activate.darwin configuration;
  };
  home = {configuration, ...}: {
    config = configuration.config.home-manager.users.${username};
  };
  inherit (result) homeSpecialArgs mkSystemConfig;
}
