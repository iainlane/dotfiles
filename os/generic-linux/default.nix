{
  inputs,
  lib,
  config,
  withSystem,
  username,
  overlays,
  nixpkgsConfig,
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
              inherit hostConfig username mcpByChannel channel modelCatalog;
            }
            // {inherit nixpkgsConfig;};
        };
    }
  );
in rec {
  deployment = {
    # sudo-rs can remove the Nix binaries from PATH; a login shell loads the
    # nix-daemon profile before activation.
    sudo = "sudo -S -i -u";
  };
  toplevel = configuration: configuration.config.build.toplevel;
  systemProfile = deployLib: configuration: {
    user = "root";
    path = deployLib.activate.custom (toplevel configuration) "$PROFILE/bin/activate";
  };
  inherit (result) homeSpecialArgs mkSystemConfig;
}
