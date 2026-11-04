{lib, ...}: let
  outputsFor = import ./outputs.nix {inherit lib;};
  checks = import ./checks/outputs.nix {inherit lib;};
  npmPackageChecks = import ./checks/npm-packages.nix {inherit lib;};
in {
  imports = [./context.nix];
  perSystem = {pkgs, ...}: let
    outputs = outputsFor {inherit pkgs;};
  in {
    inherit (outputs) packages;
    checks = lib.mkMerge [
      outputs.checks
      (checks {inherit pkgs;})
      (npmPackageChecks {inherit pkgs;})
      (import ./checks/typecheck.nix {inherit pkgs;})
    ];
    legacyPackages = {inherit (outputs) slowChecks;};
  };
}
