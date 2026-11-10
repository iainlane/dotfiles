{
  inputs,
  updaterNames,
  updaterVersions,
  lib,
  ...
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  names = discovery.discoverPackages ../../pkgs;
  maintenance = import ../../lib/package-maintenance.nix {inherit lib;};
  unversioned = lib.filter (name: (updaterVersions.${name} or "") == "") updaterNames;
in
  {
    pkgs,
    pkgs-stable,
    apps,
    updaterScripts,
    ...
  }: let
    invalidApps = lib.filter (name: !(apps ? ${"update-${name}"}) || apps ? ${name}) (lib.attrNames updaterScripts);
    errors = lib.concatMap (set:
      lib.concatMap (name:
        if lib.meta.availableOn pkgs.stdenv.hostPlatform set.${name}
        then
          maintenance.errors {
            inherit name;
            package = set.${name};
            packages = names;
            inputs = lib.attrNames inputs;
          }
        else [])
      names) [pkgs pkgs-stable];
  in
    {
      checks = {
        nix-update-updater = import ../../pkgs/build-support/nix-update-updater.test.nix {inherit pkgs;};
        pi-extension-updater = import ../../pkgs/build-support/pi-extension-updater.test.nix {inherit pkgs;};
        pi-extension-lock = assert import ../../pkgs/build-support/project-pi-npm-package.test.nix {inherit lib;};
          pkgs.runCommandLocal "pi-extension-lock" {} ''
            touch $out
          '';

        npm-lock-updater =
          pkgs.runCommandLocal "npm-lock-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.diffutils pkgs.jq];
            passthru.ci.runOnce = true;
          } ''
            bash ${../../pkgs/build-support/npm-lock-updater.test.bash} \
              ${../../pkgs/build-support/npm-lock-updater.bash}
            touch $out
          '';

        package-updater-coverage = assert import ../../lib/package-maintenance.test.nix {inherit lib;};
        assert lib.assertMsg (errors == []) "Invalid package maintenance policies:\n${lib.concatStringsSep "\n" errors}";
          pkgs.runCommandLocal "package-updater-coverage" {} ''
            touch $out
          '';

        package-updater-apps = assert lib.assertMsg (invalidApps == []) "Updater apps must use update-<package> keys: ${lib.concatStringsSep ", " invalidApps}";
          pkgs.runCommandLocal "package-updater-apps" {} ''touch "$out"'';

        package-updater-nodes = assert import ./package-node.test.nix;
          pkgs.runCommandLocal "package-updater-nodes" {} ''touch "$out"'';

        package-updater-versions = assert lib.assertMsg (unversioned == []) "Updaters without a version: ${lib.concatStringsSep ", " unversioned}";
          pkgs.runCommandLocal "package-updater-versions" {} ''
            touch $out
          '';

        flake-input-updater =
          pkgs.runCommandLocal "flake-input-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.diffutils pkgs.git pkgs.nix];
          } ''
            bash ${../../pkgs/build-support/replace-once.test.bash} \
              ${../../pkgs/build-support/replace-once.jq}
            bash ${../../pkgs/build-support/flake-branch-updater.test.bash} \
              ${lib.getExe (pkgs.updaters.mkFlakeBranchUpdater {input = "hermes-agent";})}
            touch $out
          '';
      };
    }.checks
