# The nixpkgs, Home Manager and package sets a host's `channel` selects.
#
# Two nixpkgs inputs and two Home Manager inputs are locked, and a host's
# `channel` selects one pair. The NixOS and nix-darwin configurations, both
# forms of the Home Manager configuration and the netboot installer all take
# the pair from here, so they are built from one nixpkgs. A generic-linux
# host's system configuration is the exception: system-manager evaluates it
# against the nixpkgs its own flake input follows.
{inputs}: {
  # `pkgs` and `pkgs-stable` are the package sets flake-parts instantiated for
  # the host's system, and `channel` is the host record's field. `primary` is
  # the set the host builds from. `stable` and `unstable` are both sets, for
  # a module that needs a package from the channel the host does not build
  # from.
  channelFor = {
    channel,
    pkgs,
    pkgs-stable,
  }: let
    onStable = channel == "stable";
  in {
    primary =
      if onStable
      then pkgs-stable
      else pkgs;

    stable = pkgs-stable;

    unstable = pkgs;

    nixpkgs =
      if onStable
      then inputs.nixpkgs-stable
      else inputs.nixpkgs;

    home-manager =
      if onStable
      then inputs.home-manager-stable
      else inputs.home-manager;
  };
}
