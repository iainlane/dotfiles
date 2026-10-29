{
  inputs,
  lib,
  ...
}: {
  imports = [./arguments.nix];
  perSystem = {pkgs, ...}: {
    checks = import ./checks.nix {inherit inputs lib;} {inherit pkgs;};
  };
}
