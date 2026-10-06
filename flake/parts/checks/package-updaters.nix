{
  config,
  lib,
  ...
}: let
  discovery = import ../../../lib/discovery.nix {inherit lib;};
  localOrDerived = [
    "claude-prompt-conformance"
    "flake-lock-summary"
    "hermes-inbox"
    "larapaper-image"
    "prose-lint"
    "voxtype-osd-gtk4"
  ];
  missing = lib.subtractLists (config.flake.updaterNames ++ localOrDerived) (discovery.discoverPackages ../../../pkgs);
  unversioned = lib.filter (name: (config.flake.updaterVersions.${name} or "") == "") config.flake.updaterNames;
  scripts = {
    parakeet-tdt-onnx = ../../../pkgs/parakeet-tdt-onnx;
    trmnl-liquid-cli = ../../../pkgs/trmnl-liquid-cli;
    larapaper-web-library = ../../../pkgs/build-support/larapaper-web-library;
  };
in {
  perSystem = {pkgs, ...}: {
    checks =
      {
        package-updater-coverage = assert lib.assertMsg (missing == []) "Packages without updaters: ${lib.concatStringsSep ", " missing}";
          pkgs.runCommandLocal "package-updater-coverage" {} ''
            touch $out
          '';

        package-updater-versions = assert lib.assertMsg (unversioned == []) "Updaters without a version: ${lib.concatStringsSep ", " unversioned}";
          pkgs.runCommandLocal "package-updater-versions" {} ''
            touch $out
          '';

        flake-input-updater =
          pkgs.runCommandLocal "flake-input-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.diffutils];
          } ''
            bash ${../../../pkgs/build-support/replace-once.test.sh} \
              ${../../../pkgs/build-support/replace-once.jq}
            touch $out
          '';
      }
      // lib.mapAttrs' (name: directory:
        lib.nameValuePair "${name}-updater" (
          pkgs.runCommandLocal "${name}-updater-test" {
            nativeBuildInputs = [pkgs.python3 pkgs.ruff pkgs.pyright];
          } ''
            cp ${directory}/update.py ${directory}/test_update.py .
            ruff check update.py test_update.py
            ruff format --check update.py test_update.py
            pyright --project .
            python3 -m unittest -v
            touch $out
          ''
        ))
      scripts;
  };
}
