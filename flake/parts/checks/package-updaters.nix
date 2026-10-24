{
  config,
  lib,
  ...
}: let
  discovery = import ../../../lib/discovery.nix {inherit lib;};
  declaresUpdater = name: lib.any (packages: packages ? ${name} && packages.${name} ? updateScript) (lib.attrValues config.flake.packages);
  missing = lib.filter (name: !declaresUpdater name) (discovery.discoverPackages ../../../pkgs);
  unversioned = lib.filter (name: (config.flake.updaterVersions.${name} or "") == "") config.flake.updaterNames;
in {
  perSystem = {pkgs, ...}: {
    checks = {
      pi-extension-updater = import ../../../pkgs/build-support/pi-extension-updater.test.nix {inherit pkgs;};
      pi-extension-lock = assert import ../../../pkgs/build-support/project-pi-npm-package.test.nix {inherit lib;};
        pkgs.runCommandLocal "pi-extension-lock" {} ''
          touch $out
        '';
      package-updater-coverage = assert lib.assertMsg (missing == []) "Packages without passthru.updateScript (set it to null when a package has no updater): ${lib.concatStringsSep ", " missing}";
        pkgs.runCommandLocal "package-updater-coverage" {} ''
          touch $out
        '';

      package-updater-versions = assert lib.assertMsg (unversioned == []) "Updaters without a version: ${lib.concatStringsSep ", " unversioned}";
        pkgs.runCommandLocal "package-updater-versions" {} ''
          touch $out
        '';

      flake-input-updater =
        pkgs.runCommandLocal "flake-input-updater-test" {
          nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.diffutils pkgs.git pkgs.nix];
        } ''
          bash ${../../../pkgs/build-support/replace-once.test.sh} \
            ${../../../pkgs/build-support/replace-once.jq}
          bash ${../../../pkgs/build-support/flake-branch-updater.test.bash} \
            ${lib.getExe (pkgs.updaters.mkFlakeBranchUpdater {input = "hermes-agent";})}
          touch $out
        '';
    };
  };
}
