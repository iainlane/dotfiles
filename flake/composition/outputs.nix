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
    flakeContexts,
    system,
    ...
  }:
    outputs.forSystem {
      inherit pkgs pkgs-stable system hostResults flakeContexts;
      inherit (config.dotfiles) hosts flakeSystem;
    };
}
