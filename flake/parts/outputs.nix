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
  flake.outputFeatures = with config.flake.features; [
    ai
    ai.provides.claude-code.provides.teamclaude
    development
    work
    home.provides.debian
    agentsview
    agentsview.provides.embeddings.provides.local
    hermes
    unifi
  ];
  perSystem = {
    pkgs,
    pkgs-stable,
    system,
    ...
  }:
    outputs.forSystem {
      inherit pkgs pkgs-stable system hostResults;
      inherit (config.flake) hosts outputFeatures outputExcludes;
    };
}
