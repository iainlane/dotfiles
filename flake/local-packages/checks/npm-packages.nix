{lib, ...}: let
  npmPackages = import ../../../lib/npm-packages.nix {inherit lib;};

  producer = name: version: {
    meta.identifiers.purlParts = npmPackages.purlParts {inherit name version;};
    npmTarball = "/nix/store/${name}.tgz";
  };
  host = producer "@scope/host" "2.0.0";
  linked = producer "linked" "1.0.0";
  github.meta.identifiers.purlParts = {
    type = "github";
    spec = "owner/repo@v1.0.0";
  };
  plain.meta = {};

  registry = {
    resolved = "https://registry.npmjs.org/@scope/host/-/host-1.0.0.tgz";
    integrity = "sha512-registry";
    version = "2.0.0";
  };
  other = {
    resolved = "https://registry.npmjs.org/other/-/other-1.0.0.tgz";
    integrity = "sha512-other";
    version = "1.0.0";
  };
  packageLock = {
    lockfileVersion = 3;
    packages = {
      "" = {name = "consumer";};
      "node_modules/@scope/host" = registry;
      "node_modules/other" = other;
      "node_modules/other/node_modules/@scope/host" = registry;
      "node_modules/alias" = registry // {name = "@scope/host";};
      "node_modules/linked" = {
        resolved = "packages/linked";
        link = true;
      };
    };
  };
  withoutIntegrity = removeAttrs registry ["integrity"];
in
  {pkgs, ...}:
    (
      let
        command = name:
          pkgs.writeShellApplication {
            inherit name;
            text = ''printf '${name}:%s:%s\n' "$PWD" "$*" >>"$UPDATE_LOG"'';
          };
        updaters = pkgs.callPackage ../../../pkgs/build-support/updaters.nix {nix-update = command "nix-update";};
        updater = updaters.mkPnpmLockUpdater {
          pname = "fixture";
          directory = "fixture";
          packages = [host linked];
          pnpm = command "pnpm";
          systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
        };
        assertions = [
          {
            name = "an npm purl percent-encodes the scope";
            pass =
              host.meta.identifiers.purlParts
              == {
                type = "npm";
                spec = "%40scope/host@2.0.0";
              };
          }
          {
            name = "only npm purls describe npm packages";
            pass =
              map npmPackages.npmPackage [host github plain]
              == [
                {
                  name = "@scope/host";
                  version = "2.0.0";
                }
                null
                null
              ];
          }
          {
            name = "packages are keyed by npm name";
            pass = npmPackages.byName {inherit host github plain;} == {"@scope/host" = host;};
          }
          {
            name = "attribute names are keyed by npm name";
            pass = npmPackages.attributesByName {inherit host github plain;} == {"@scope/host" = "host";};
          }
          {
            name = "pnpm selects local providers from package keys, including transitive packages";
            pass =
              npmPackages.providePnpm {
                packages = npmPackages.byName {
                  inherit host linked;
                  unscoped = producer "host" "2.0.0";
                  unused = producer "unused" "1.0.0";
                };
                lockfile = ''
                  lockfileVersion: '9.0'
                  packages:
                    '@scope/host@2.0.0':
                      resolution: {integrity: sha512-registry}
                    linked@1.0.0:
                      resolution: {integrity: sha512-linked}
                  snapshots:
                    '@scope/host@2.0.0(linked@1.0.0)': {}
                '';
              }
              == [host linked];
          }
          {
            name = "pnpm selects providers from double-quoted package keys";
            pass =
              npmPackages.providePnpm {
                packages = npmPackages.byName {inherit host linked;};
                lockfile = ''
                  packages:
                    "@scope/host@2.0.0": {}
                    "linked@1.0.0": {}
                '';
              }
              == [host linked];
          }
          {
            name = "every lockfile entry for a local package, including an alias, installs its tarball";
            pass =
              npmPackages.provide {
                packages = npmPackages.byName {inherit host linked;};
                inherit packageLock;
              }
              == {
                packageLock =
                  packageLock
                  // {
                    packages =
                      packageLock.packages
                      // {
                        "node_modules/@scope/host" = withoutIntegrity;
                        "node_modules/other/node_modules/@scope/host" = withoutIntegrity;
                        "node_modules/alias" = withoutIntegrity // {name = "@scope/host";};
                      };
                  };
                packageSourceOverrides = {
                  "node_modules/@scope/host" = host.npmTarball;
                  "node_modules/other/node_modules/@scope/host" = host.npmTarball;
                  "node_modules/alias" = host.npmTarball;
                };
                provided = [host];
              };
          }
        ];
        failures = lib.filter (assertion: !assertion.pass) assertions;
        report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;
      in {
        checks.npm-packages =
          pkgs.runCommandLocal "npm-packages" {
            inherit report;
            nativeBuildInputs = [pkgs.nodejs_24 pkgs.gitMinimal pkgs.jq pkgs.diffutils];
            passthru.ci.runOnce = true;
          } ''
            if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
            bash ${../../../pkgs/build-support/pnpm-local-packages.test.bash} ${../../../pkgs/build-support/pnpm-local-packages.cjs}
            bash ${../../../pkgs/build-support/pnpm-lock-updater.test.bash} ${lib.getExe updater}
            touch "$out"
          '';
      }
    ).checks
