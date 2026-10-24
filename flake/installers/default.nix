{
  config,
  inputs,
  lib,
  featureResolver,
  hostResults,
  withSystem,
  ...
}: let
  outputs = import ./outputs.nix {
    inherit inputs lib featureResolver withSystem;
    nixosHosts = lib.filterAttrs (_: host: featureResolver.isNixos (featureResolver.contextForHost host)) config.dotfiles.hosts;
    hostToplevels = lib.mapAttrs (_: result: result.toplevel) hostResults;
    inherit (config.dotfiles.nix) substitutersModule;
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
    checks = import ../../lib/netboot/check.nix {inherit lib;} args;
  };
}
