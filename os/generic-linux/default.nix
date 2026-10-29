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
        inherit hostConfig mcpByChannel modelCatalog pkgs pkgs-stable flakeContexts;
        hostInventory = hostInventories.${hostConfig.name};
      };
      home = {homeDefinition, ...}: let
        standalone = home.mkHomeConfiguration {
          homeManager = channel.home-manager;
          pkgs = channel.primary;
          inherit (homeDefinition) modules extraSpecialArgs;
        };
      in {
        inherit (standalone) config;
        inherit standalone;
      };
      mkSystemConfig = _:
        inputs.system-manager.lib.makeSystemConfig {
          modules =
            [
              ./nixpkgs.nix
              sops.systemSopsModule
              sops.linuxSystemSopsModule
              ./system.nix
              inputs.sops-nix.nixosModules.sops
              config.dotfiles.nix.substitutersModule
            ]
            ++ resolveFeatures {
              class = "systemManager";
              inherit hostConfig;
            }
            ++ [hostConfig.systemModule];
          # Special arguments take precedence over the `pkgs` that system-manager
          # imports into `_module.args`, so its own package set is never
          # evaluated.
          specialArgs =
            mkSystemSpecialArgs {
              inherit hostConfig username mcpByChannel channel modelCatalog flakeContexts;
              hostInventory = hostInventories.${hostConfig.name};
            }
            // {pkgs = channel.unstable;};
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
  inherit (result) home homeSpecialArgs mkSystemConfig;
}
