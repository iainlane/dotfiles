{
  config,
  inputs,
  lib,
  hostResults,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit inputs lib hostResults;
    inherit (config.dotfiles) hosts username;
  };
  tools = import ./tools.nix {inherit inputs lib;};
in {
  flake = {inherit (outputs) deploy;};
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    args = {inherit pkgs system lib;};
  in {
    packages = tools.packages args;
    apps = tools.apps args;
    checks = outputs.checks args;
  };
}
