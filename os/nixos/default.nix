{
  inputs,
  lib,
  config,
  withSystem,
  helpers,
  username,
  ...
}: hostname: hostConfig: let
  channelPkgs = {
    pkgs,
    pkgs-stable,
  }:
    if hostConfig.channel == "stable"
    then {
      primary = pkgs-stable;
      secondary = pkgs;
      stable = pkgs-stable;
      unstable = pkgs;
      nixpkgs = inputs.nixpkgs-stable;
      home-manager = inputs.home-manager-stable;
    }
    else {
      primary = pkgs;
      secondary = pkgs-stable;
      stable = pkgs-stable;
      unstable = pkgs;
      inherit (inputs) nixpkgs;
      inherit (inputs) home-manager;
    };

  result = withSystem hostConfig.system (
    {
      pkgs,
      pkgs-stable,
      ...
    }: let
      channel = channelPkgs {
        inherit pkgs pkgs-stable;
      };
      homeSpecialArgs = {
        inherit (channel) secondary;
        inherit inputs;
        pkgs-stable = channel.stable;
        pkgs-unstable = channel.unstable;
      };
      homeConfig = helpers.mkHomeConfiguration {
        inherit
          hostConfig
          hostname
          username
          ;
        inherit (hostConfig) system;
        inherit (config.flake) profiles modules;
        extraSpecialArgs = homeSpecialArgs;
      };

      # The unstable home-manager program modules grafted on by
      # modules/ai/unstable-hm-modules.nix are written against unstable's
      # `lib.hm`, which carries helpers (such as
      # `generators.mkDAGOrderedJsonFormat`) that the stable channel's `lib.hm`
      # does not yet have. Build an extended lib whose `lib.hm` comes from
      # unstable and hand it to the home-manager modules on stable hosts.
      # `extraSpecialArgs` takes precedence over the home-manager module's own
      # `lib`, so this overrides it without rebuilding the stable source.
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
      systemConfig = channel.nixpkgs.lib.nixosSystem {
        inherit (hostConfig) system;
        pkgs = channel.primary;
        modules =
          [
            helpers.mkSystemSopsModule
            ../../hosts/${hostname}/hardware.nix
            ../../hosts/${hostname}/disks.nix
            ./system.nix
            inputs.disko.nixosModules.disko
            inputs.sops-nix.nixosModules.sops
            inputs.lanzaboote.nixosModules.lanzaboote
            config.flake.nix.substitutersModule
          ]
          ++ helpers.mkModules {
            moduleType = "nixosModule";
            inherit hostConfig;
            inherit (config.flake) profiles modules;
          }
          ++ lib.optional (hostConfig.nixosModule != null) hostConfig.nixosModule
          ++ [
            channel.home-manager.nixosModules.home-manager
            (helpers.mkEmbeddedHomeManager {
              inherit username homeConfig;
              extraSpecialArgs = lib.optionalAttrs (hostConfig.channel == "stable") {lib = unstableHmLib;};
            })
          ];
        specialArgs = {
          inherit
            inputs
            hostname
            hostConfig
            username
            ;
          pkgs-stable = channel.stable;
          pkgs-unstable = channel.unstable;
        };
      };
    }
  );
in {
  homeBaseDir = "/home";
  systemSuffix = "linux";
  inherit (result) homeSpecialArgs systemConfig;
}
