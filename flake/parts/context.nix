# Declares `flake.username`, and exposes `overlays` and `nixpkgsConfig` as
# module arguments. The other flake-parts modules use them when they import
# nixpkgs.
{
  inputs,
  lib,
  ...
}: let
  inherit (import ../../lib/discovery.nix {inherit lib;}) importNixFiles;

  # Discovered from `overlays/*.nix` in sorted order and instantiated with the
  # shared `{inputs}` argument.
  overlays = importNixFiles ../../overlays {inherit inputs;};

  nixpkgsConfig = {
    allowUnfree = true;
  };
in {
  options.flake.username = lib.mkOption {
    type = lib.types.str;
    default = "laney";
    description = "Primary user account managed across all hosts.";
  };

  config = {
    _module.args = {
      inherit overlays nixpkgsConfig;
    };

    perSystem = {system, ...}: let
      mkPkgs = nixpkgs:
        import nixpkgs {
          inherit system overlays;
          config = nixpkgsConfig;
        };
      pkgs = mkPkgs inputs.nixpkgs;
      pkgs-stable = mkPkgs inputs.nixpkgs-stable;
    in {
      _module.args = {inherit pkgs pkgs-stable;};

      # `./just` runs `nh` from this flake's unstable package set.
      packages.nh = pkgs.nh;
    };
  };
}
