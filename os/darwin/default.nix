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
  inherit (import ../../lib/channels.nix {inherit inputs;}) channelFor;

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
      homeSpecialArgs = {
        mcp = mcpByChannel.${hostConfig.channel};
        pkgs-unstable = channel.unstable;
      };
    in {
      inherit homeSpecialArgs;
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
          specialArgs = {
            inherit
              inputs
              hostConfig
              username
              ;
            mcp = mcpByChannel.${hostConfig.channel};
            pkgs-stable = channel.stable;
            pkgs-unstable = channel.unstable;
          };
        };
    }
  );
in {
  homeBaseDir = "/Users";
  systemSuffix = "darwin";
  inherit (result) homeSpecialArgs mkSystemConfig;
}
