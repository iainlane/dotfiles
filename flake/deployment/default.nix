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
  tools = import ./tools.nix {
    inherit inputs lib;
    deployPackageFor = system: flakeContexts.${system}.deployRs.deploy-rs;
  };
in {
  flake = {inherit (outputs) deploy;};
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    args = {inherit pkgs system lib;};
  in {
    dotfiles.shared.deployRs = import ../../lib/deploy-rs {inherit inputs system;};
    packages = tools.packages args;
    apps = tools.apps args;
    checks = outputs.checks args // import ./test.nix args;
  };
}
