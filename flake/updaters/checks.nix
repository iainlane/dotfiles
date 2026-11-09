{
  packages,
  updaterNames,
  updaterVersions,
  lib,
  ...
}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  declaresUpdater = name: lib.any (packages: packages ? ${name} && packages.${name} ? updateScript) (lib.attrValues packages);
  missing = lib.filter (name: !declaresUpdater name) (discovery.discoverPackages ../../pkgs);
  unversioned = lib.filter (name: (updaterVersions.${name} or "") == "") updaterNames;
in
  {pkgs, ...}:
    {
      checks = {
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

        pnpm-lock-updater = let
          command = name:
            pkgs.writeShellApplication {
              inherit name;
              text = ''printf '${name}:%s:%s\n' "$PWD" "$*" >>"$UPDATE_LOG"'';
            };
          npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
          producer = name: version: manifest: {
            meta.identifiers.purlParts = npmPackages.purlParts {inherit name version;};
            npmTarball =
              pkgs.runCommandLocal "${baseNameOf name}-${version}.tgz" {
                manifest = builtins.toJSON ({inherit name version;} // manifest);
                passAsFile = ["manifest"];
              } ''
                mkdir package
                cp "$manifestPath" package/package.json
                tar -czf "$out" package
              '';
          };
          npm = pkgs.writeShellApplication {
            name = "npm";
            text = ''
              printf 'npm:%s:%s\n' "$PWD" "$*" >>"$UPDATE_LOG"
              cat "$REGISTRY/''${2//\//+}.json"
            '';
          };
          updater =
            (pkgs.updaters.override {
              nix-update = command "nix-update";
              nodejs = npm;
            }).mkPnpmLockUpdater {
              pname = "fixture";
              directory = "fixture";
              packages = [
                (producer "@scope/host" "2.0.0" {
                  dependencies.shared = "^1";
                  peerDependencies.peer = "*";
                })
                (producer "linked" "1.0.0" {})
              ];
              pnpm = command "pnpm";
            };
        in
          pkgs.runCommandLocal "pnpm-lock-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.diffutils pkgs.gitMinimal pkgs.jq pkgs.yq-go];
            passthru.ci.runOnce = true;
          } ''
            bash ${../../pkgs/build-support/pnpm-lock-updater.test.bash} ${lib.getExe updater}
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
            bash ${../../pkgs/build-support/replace-once.test.bash} \
              ${../../pkgs/build-support/replace-once.jq}
            bash ${../../pkgs/build-support/flake-branch-updater.test.bash} \
              ${lib.getExe (pkgs.updaters.mkFlakeBranchUpdater {input = "hermes-agent";})}
            touch $out
          '';
      };
    }.checks
