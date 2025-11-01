{
  inputs,
  lib,
  ...
}:
# This module provides shared context and configuration used across all flake outputs.
# It's the single source of truth for host inventory, helper utilities, and pkgs configuration.
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
  # imported. New hosts appear automatically when added to `hosts/`.
  #
  # Each host file provides `{ hostname, os, arch, modules, homeModule? }`. This
  # function adds a computed `homeDirectory` field derived from the OS type, so
  # downstream code can use `hostConfig.homeDirectory` without having to
  # recalculate it.
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
  ];

  # Common nixpkgs config used across all systems
  nixpkgsConfig = {
    allowUnfree = true;
  };

  # Helper to create pkgs for a specific system
  mkPkgs = system:
    import inputs.nixpkgs {
      inherit system overlays;
      config = nixpkgsConfig;
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
        mkPkgs
        ;
    };

    perSystem = {system, ...}: {
      # Override pkgs with our custom configuration
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system overlays;
        config = nixpkgsConfig;
      };
    };
  };
}
