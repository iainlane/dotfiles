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

  # Helper to compute home directory based on OS
  mkHomeDirectory = os:
    if os == "darwin"
    then "/Users/${username}"
    else if os == "linux"
    then "/home/${username}"
    else throw "Unsupported OS: ${os}";

  # Discover `hosts/*.nix` files automatically. The `filterAttrs` finds `.nix`
  # files, `mapAttrs` strips extensions to produce hostnames, then each file is
  # imported. This makes new hosts appear automatically when added to `hosts/`.
  #
  # Each host file provides `{ hostname, os, arch, modules, homeModule? }`. This
  # function adds a computed `homeDirectory` field derived from the OS type.
  hosts = lib.pipe (builtins.readDir ../../hosts) [
    (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name))
    (lib.mapAttrs' (name: _: let
      hostConfig = import (../../hosts + "/${name}");
    in
      lib.nameValuePair
      (lib.removeSuffix ".nix" name)
      (hostConfig // {homeDirectory = mkHomeDirectory hostConfig.os;})))
  ];

  darwinHosts = lib.filterAttrs (_: hostConfig: hostConfig.os == "darwin") hosts;
  linuxHosts = lib.filterAttrs (_: hostConfig: hostConfig.os == "linux") hosts;

  # Common overlays used across all systems
  overlays = [
    inputs.fenix.overlays.default
    (import ../../overlays/google-chrome.nix)
  ];

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
