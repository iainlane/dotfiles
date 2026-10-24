{lib, ...}: let
  outputsFor = import ./outputs.nix {inherit lib;};
  checks = import ./checks/outputs.nix {inherit lib;};
in {
  imports = [./context.nix];
  perSystem = {pkgs, ...}: let
    outputs = outputsFor {inherit pkgs;};
  in {
    inherit (outputs) packages;
    checks = lib.mkMerge [outputs.checks (checks {inherit pkgs;})];
    legacyPackages = {inherit (outputs) slowChecks;};
  };
}
