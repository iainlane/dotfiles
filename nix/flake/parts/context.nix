{
  inputs,
  lib,
  ...
}:
# Shared context available to all flake-parts modules.
#
# This is a flake-parts module (notice it returns a `config` attrset at the end).
# It sets up values that other modules need:
# - `context.hosts`: all hosts discovered from hosts/*.nix
# - `context.helpers`: utility functions from lib/helpers.nix
# - `pkgs`: a configured nixpkgs instance with our overlays
#
# Other modules access these via `config.context.*` or the `pkgs` argument.
#
# Key concepts for Nix newcomers:
# - `lib.pipe x [f g h]` is like `h(g(f(x)))` - chains function calls
# - `lib.filterAttrs` filters an attrset by a predicate
# - `lib.mapAttrs'` transforms both keys and values of an attrset
# - `inputs.self.outputs` refers to this flake's own outputs
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
  # Each host file provides `{ hostname, os, arch, profiles, homeModule? }`. This
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

    perSystem = {system, ...}: {
      # Override pkgs with our custom configuration
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system overlays;
        config = nixpkgsConfig;
      };
    };
  };
}
