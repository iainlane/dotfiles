# Marks a host that deploy-rs deploys, and builds deploy-rs's flake outputs.
# Only hosts with this feature get deploy-rs nodes and activation checks, and CI
# publishes their deploy-rs profiles. Other hosts are switched locally, so CI
# publishes their system and home outputs.
{
  config,
  inputs,
  lib,
  hostResults,
  flakeContexts,
  featureResolver,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit lib hostResults;
    inherit (config.dotfiles) username;
    hosts = lib.filterAttrs (_: host: featureResolver.hasFeature host config.dotfiles.features.deploy-rs) config.dotfiles.hosts;
    deployLibFor = system: flakeContexts.${system}.deployRs.lib;
  };
in {
  dotfiles.features.deploy-rs = {};

  flake = {inherit (outputs) deploy;};

  perSystem = {
    pkgs,
    system,
    ...
  }: let
    deployRs = import ../../lib/deploy-rs {inherit inputs system;};
  in {
    dotfiles.shared = {inherit deployRs;};

    packages.deploy-rs = deployRs.deploy-rs;

    apps.deploy-rs = {
      type = "app";
      program = lib.getExe deployRs.deploy-rs;
      meta.description = "Multi-profile Nix deployment tool";
    };

    checks = outputs.checks {inherit system;} // import ./test.nix {inherit pkgs lib;};
  };
}
