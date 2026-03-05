{
  inputs,
  lib,
  config,
  ...
}:
# This module provides shared context and configuration used across all flake
# outputs. It's the single source of truth for host inventory, helper utilities,
# and pkgs configuration.
let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  username = "laney";

  # Discover `hosts/*.nix` files automatically and annotate each host with a
  # computed `homeDirectory`.
  hosts = helpers.addHostHomeDirectories {
    inherit (helpers) hosts;
    inherit username;
  };

  darwinHosts = lib.filterAttrs (_: hostConfig: hostConfig.os == "darwin") hosts;
  linuxHosts = lib.filterAttrs (_: hostConfig: hostConfig.os == "linux") hosts;

  # Common overlays used across all systems.
  # Local overlays are discovered automatically from `overlays/*.nix` (sorted)
  # and instantiated with the shared `{ inputs }` contract.
  overlays = helpers.importNixFiles ../../overlays {inherit inputs;};

  # Common nixpkgs configuration used across all systems
  nixpkgsConfig = {
    allowUnfree = true;
  };
in {
  config = {
    _module.args.context = {
      inherit
        lib
        helpers
        username
        hosts
        darwinHosts
        linuxHosts
        overlays
        nixpkgsConfig
        ;
    };

    # Make packages available under:
    #
    #   .#hostPrograms.<hostname>.nh.package
    #
    # and then external consumers like `./just` can run the same versions using
    # `nix run`.
    flake.hostPrograms =
      lib.mapAttrs (
        hostname: _:
          if config.flake.darwinConfigurations ? ${hostname}
          then config.flake.darwinConfigurations.${hostname}.config.home-manager.users.${username}.programs
          else config.flake.homeConfigurations."${username}@${hostname}".config.programs
      )
      hosts;

    perSystem = {system, ...}: let
      pkgs = import inputs.nixpkgs {
        inherit system overlays;
        config = nixpkgsConfig;
      };
    in {
      _module.args.pkgs = pkgs;
    };
  };
}
