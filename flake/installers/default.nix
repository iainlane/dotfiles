{
  config,
  inputs,
  lib,
  featureResolver,
  withSystem,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit inputs lib featureResolver withSystem config;
    nixosHosts = lib.filterAttrs (_: host: featureResolver.isNixos (featureResolver.contextForHost host)) config.dotfiles.hosts;
  };
in {
  perSystem = {
    pkgs,
    pkgs-stable,
    system,
    ...
  }: let
    args = {inherit pkgs pkgs-stable system;};
  in {
    packages = outputs.packages args;
    apps = outputs.apps args;
  };
}
