# Resolves a host's `channel` to the locked nixpkgs and Home Manager inputs and
# the package sets built from them.
{inputs}: {
  # `pkgs` and `pkgs-stable` are the two package sets flake-parts instantiated
  # for the host's system.
  #
  # `primary` is the set that the host builds from. `stable` and `unstable` are
  # returned whatever the channel, for a module that needs a package from the
  # channel that the host does not build from. `nixpkgs` and `home-manager` are
  # the flake inputs themselves, for a caller that needs their modules or
  # `lib`.
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
