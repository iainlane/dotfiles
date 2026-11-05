# deploy-rs's flake outputs: a node for each host, the deployment checks, and
# the deploy-rs package and app.
{
  config,
  inputs,
  lib,
  hostResults,
  flakeContexts,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit lib hostResults;
    inherit (config.dotfiles) hosts username;
    deployLibFor = system: flakeContexts.${system}.deployRs.lib;
  };
in {
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
