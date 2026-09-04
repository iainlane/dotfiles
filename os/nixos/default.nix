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

  channelPkgs = {
    pkgs,
    pkgs-stable,
  }:
    if hostConfig.channel == "stable"
    then {
      primary = pkgs-stable;
      stable = pkgs-stable;
      unstable = pkgs;
      nixpkgs = inputs.nixpkgs-stable;
      home-manager = inputs.home-manager-stable;
    }
    else {
      primary = pkgs;
      stable = pkgs-stable;
      unstable = pkgs;
      inherit (inputs) nixpkgs;
      inherit (inputs) home-manager;
    };

  result = withSystem hostConfig.system (
    {
      mcpByChannel,
      pkgs,
      pkgs-stable,
      ...
    }: let
      channel = channelPkgs {
        inherit pkgs pkgs-stable;
      };
      homeSpecialArgs =
        {
          inherit inputs;
          mcp = mcpByChannel.${hostConfig.channel};
          pkgs-stable = channel.stable;
          pkgs-unstable = channel.unstable;
        }
        // lib.optionalAttrs (hostConfig.channel == "stable") {lib = unstableHmLib;};
      # The unstable home-manager program modules grafted on by
      # features/ai/unstable-hm-modules.nix are written against unstable's
      # `lib.hm`, which carries helpers (such as
      # `generators.mkDAGOrderedJsonFormat`) that the stable channel's `lib.hm`
      # does not yet have. Build an extended lib whose `lib.hm` comes from
      # unstable and hand it to the home-manager modules on stable hosts via
      # `homeSpecialArgs`, so both the embedded and standalone configurations
      # receive it. Special args take precedence over the home-manager module's
      # own `lib`, so this overrides it without rebuilding the stable source.
      unstableHmLib = channel.stable.lib.extend (
        self: super: let
          hmLib = import "${inputs.home-manager}/modules/lib" {lib = self;};
        in {
          hm = hmLib;
          maintainers = super.maintainers // hmLib.maintainers;
        }
      );
    in {
      inherit homeSpecialArgs;
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
  homeBaseDir = "/home";
  systemSuffix = "linux";
  inherit (result) homeSpecialArgs mkSystemConfig;
}
