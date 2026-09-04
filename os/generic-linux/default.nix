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
    in {
      homeSpecialArgs = home.mkHomeSpecialArgs {
        inherit hostConfig mcpByChannel pkgs pkgs-stable;
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
            pkgs-unstable = channel.unstable;
          };
        };
    }
  );
in {
  inherit (result) homeSpecialArgs mkSystemConfig;
}
