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
        inherit (config.flake) profiles;
        extraSpecialArgs = homeSpecialArgs;
      };

      # The shared AI modules import program modules from unstable home-manager,
      # which rely on `lib.hm` helpers (`mcp`, `strings.isPathLike`, ...) the
      # stable release does not ship. Hand the embedded home-manager unstable's
      # whole `lib.hm`, the same set the standalone `homeConfigurations` already
      # evaluate against; `extraSpecialArgs` takes precedence over
      # home-manager's own `lib`. The throw makes this fail loudly once stable
      # provides the helpers, so it is removed rather than left as dead code.
      hmLibShim = lib.optionalAttrs (hostConfig.channel == "stable") {
        lib = let
          extended = import "${channel.home-manager}/modules/lib/stdlib-extended.nix" channel.nixpkgs.lib;
        in
          extended.extend (final: prev:
            if (prev.hm ? mcp) && (prev.hm.strings ? isPathLike)
            then throw "home-manager-stable now ships the lib.hm helpers; drop the hmLibShim in os/nixos/default.nix"
            else {
              hm = import "${inputs.home-manager}/modules/lib" {lib = final;};
            });
      };
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
            inherit (config.flake) profiles;
          }
          ++ lib.optional (hostConfig.nixosModule != null) hostConfig.nixosModule
          ++ [
            channel.home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                users.${username}.imports = homeConfig.modules;
                extraSpecialArgs = homeConfig.extraSpecialArgs // hmLibShim;
              };
            }
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
