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
    in {
      homeSpecialArgs = home.mkHomeSpecialArgs {
        inherit hostConfig mcpByChannel pkgs pkgs-stable;
      };
      mkSystemConfig = homeDefinition:
        channel.nixpkgs.lib.nixosSystem {
          inherit (hostConfig) system;
          pkgs = channel.primary;
          modules =
            [
              sops.systemSopsModule
              sops.linuxSystemSopsModule
              ../../hosts/${hostConfig.name}/hardware.nix
              ../../hosts/${hostConfig.name}/disks.nix
              ./system.nix
              inputs.disko.nixosModules.disko
              inputs.sops-nix.nixosModules.sops
              inputs.lanzaboote.nixosModules.lanzaboote
              config.flake.nix.substitutersModule
            ]
            ++ resolveFeatures {
              class = "nixos";
              inherit hostConfig;
            }
            ++ [
              hostConfig.systemModule
              channel.home-manager.nixosModules.home-manager
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
  inherit (result) homeSpecialArgs mkSystemConfig;
}
