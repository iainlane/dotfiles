# Checks that each package in the Hermes Python overrides is the same
# derivation in the Hermes package set and in its build-time package set.
# Nixpkgs takes a Python package's build-time inputs, such as Sphinx or mypy,
# from `python.pythonOnBuildForHost.pkgs`, so an override that reaches only
# the host package set leaves those inputs depending on the unpatched package.
#
# The overrides are platform-specific, so every check evaluates the package
# sets of all the flake's systems.
{
  config,
  inputs,
  lib,
  withSystem,
  ...
}: let
  mismatchesFor = system:
    withSystem system ({pkgs, ...}: let
      scope = import ../../../lib/hermes-python.nix {inherit inputs lib pkgs;};
      buildScope = scope.python.pythonOnBuildForHost.pkgs;
      overrides = import ../../../lib/hermes-python-overrides.nix {
        inherit (pkgs) fetchpatch lib stdenv;
      };
      names = lib.attrNames (overrides {} scope);
    in
      map (name: "${system}: ${name}") (
        lib.filter (name: scope.${name}.drvPath != buildScope.${name}.drvPath) names
      ));

  mismatches = lib.concatMap mismatchesFor config.systems;
  report = lib.concatMapStringsSep "\n" (mismatch: "  ✗ ${mismatch}") mismatches;
in {
  perSystem = {pkgs, ...}: {
    checks.hermes-python-overrides =
      pkgs.runCommandLocal "hermes-python-overrides" {inherit report;}
      (
        if mismatches == []
        then "touch $out"
        else ''
          echo "these packages differ between the Hermes Python set and its build-time set:" >&2
          printf '%s\n' "$report" >&2
          exit 1
        ''
      );
  };
}
