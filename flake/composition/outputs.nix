{
  config,
  lib,
  inputs,
  featureResolver,
  hostResults,
  ...
}: let
  outputs = import ../../lib/feature-outputs.nix {inherit lib inputs featureResolver;};
in {
  perSystem = {
    pkgs,
    pkgs-stable,
    system,
    ...
  }:
    outputs.forSystem {
      inherit pkgs pkgs-stable system hostResults;
      inherit (config.dotfiles) hosts flakeSystem;
    };
}
