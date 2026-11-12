{
  flakeContexts,
  inputs,
  lib,
  ...
}: let
  inherit (import ../../lib/discovery.nix {inherit lib;}) importNixFiles;

  # Discovered from `overlays/*.nix` in sorted order. Each overlay function
  # receives the arguments that it requests from `inputs` and `flakeContexts`.
  overlays = importNixFiles ../../overlays {inherit flakeContexts inputs;};

  nixpkgsConfig = import ../../lib/nixpkgs-config.nix;
in {
  config = {
    perSystem = {system, ...}: let
      mkPkgs = nixpkgs: overlays:
        import nixpkgs {
          inherit system overlays;
          config = nixpkgsConfig;
        };
      pkgs = mkPkgs inputs.nixpkgs overlays;
      pkgs-stable = mkPkgs inputs.nixpkgs-stable overlays;

      # The nixpkgs flake's `legacyPackages` reads `config` and overlays from
      # the user's environment when evaluation is impure.
      upstreamPackageSets = {
        nixpkgs = mkPkgs inputs.nixpkgs [];
        nixpkgs-stable = mkPkgs inputs.nixpkgs-stable [];
      };
    in {
      _module.args = {inherit pkgs pkgs-stable;};
      dotfiles.shared = {inherit pkgs pkgs-stable upstreamPackageSets;};
    };
  };
}
