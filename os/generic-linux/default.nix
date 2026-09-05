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
  inherit (import ../../lib/system.nix {inherit inputs;}) mkSystemSpecialArgs;

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
          # system-manager evaluates nixpkgs itself, and `nixpkgsConfig` is what
          # a module needs to instantiate a package set that matches the host's.
          specialArgs =
            mkSystemSpecialArgs {
              inherit hostConfig username mcpByChannel channel;
            }
            // {inherit nixpkgsConfig;};
        };
    }
  );
in {
  inherit (result) homeSpecialArgs mkSystemConfig;
}
