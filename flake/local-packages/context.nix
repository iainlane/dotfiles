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
  config = {
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
      dotfiles.shared = {inherit pkgs pkgs-stable;};
    };
  };
}
