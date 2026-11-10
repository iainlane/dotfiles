{
  lib,
  pkgs,
}: let
  call = import ./local-package.nix {inherit lib;};
  upstream = lib.makeOverridable ({extraPackages ? []}: pkgs.runCommand "override-fixture" {inherit extraPackages;} ''touch "$out"'') {};
  modified = call {
    inherit pkgs;
    path = ../flake/local-packages/checks/modified-package.nix;
    args.upstreamPackage = upstream;
  };
  overridden = modified.override {extraPackages = ["extra"];};
in
  assert overridden.extraPackages == ["extra"];
  assert overridden.modified; true
