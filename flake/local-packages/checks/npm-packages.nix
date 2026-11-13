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
        # `nix eval` prints `$NIX_EVAL`, and `nix build` prints `$NIX_BUILD`.
        nix = pkgs.writeShellApplication {
          name = "nix";
          text = ''
            printf 'nix:%s:%s\n' "$PWD" "$*" >>"$UPDATE_LOG"

            case "$1" in
            eval)
              printf '%s\n' "$NIX_EVAL"
              ;;
            build)
              printf '%s\n' "$NIX_BUILD"
              ;;
            esac
          '';
        };
        updaters = pkgs.callPackage ../../../pkgs/build-support/updaters.nix {
          nix-update = command "nix-update";
          inherit nix;
        };
        # Each call copies the next lockfile from `$PNPM_LOCKS` when it is set.
        pnpm = pkgs.writeShellApplication {
          name = "pnpm";
          text = ''
            printf 'pnpm:%s:%s\n' "$PWD" "$*" >>"$UPDATE_LOG"
            if [[ -n "''${PNPM_LOCKS:-}" ]]; then
              count=$(($(cat "$PNPM_LOCKS/count" 2>/dev/null || echo 0) + 1))
              echo "$count" >"$PNPM_LOCKS/count"
              cp "$PNPM_LOCKS/$count.yaml" pnpm-lock.yaml
            fi
          '';
        };
        updater = updaters.mkPnpmLockUpdater {
          pname = "fixture";
          directory = "fixture";
          overrides = map npmPackages.pnpmProvider [host linked];
          inherit pnpm;
          systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
        };
        updaterWithLockfiles = updaters.mkPnpmLockUpdater {
          pname = "scenario";
          directory = "scenario";
          overrides = map npmPackages.pnpmProvider [host linked];
          inherit pnpm;
          systems = ["aarch64-darwin" "x86_64-linux"];
        };
        updaterWithoutProviders = updaters.mkPnpmLockUpdater {
          pname = "plain";
          directory = "plain";
          overrides = [];
          inherit pnpm;
          systems = ["aarch64-darwin" "x86_64-linux"];
        };
        assertions =
          [
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
                };
            }
          ]
          ++ map (case: {
            name = "pnpm overrides include an npm alias that ${case.user} uses, not other references to the package";
            pass =
              map (override: {inherit (override) name file;}) (npmPackages.pnpmOverrides {
                packages = npmPackages.byName {inherit host;};
                lockfile = ''
                  packages:
                    '@scope/host@2.0.0':
                      resolution: {integrity: sha512-registry}
                  ${case.lockfile}
                '';
              })
              == [
                {
                  name = "@scope/host";
                  file = "scope-host-2.0.0.tgz";
                }
                {
                  name = "@old/host";
                  file = "scope-host-2.0.0.tgz";
                }
              ];
          }) [
            {
              user = "the project";
              lockfile = ''
                importers:
                  .:
                    devDependencies:
                      '@old/host':
                        specifier: npm:@scope/host@2.0.0
                        version: '@scope/host@2.0.0'
                      consumer:
                        specifier: ^1
                        version: 1.0.0(@scope/host@2.0.0)
              '';
            }
            {
              user = "a dependency";
              lockfile = ''
                snapshots:
                  consumer@1.0.0:
                    dependencies:
                      '@old/host': '@scope/host@2.0.0'
                      '@scope/host': 2.0.0
                    peerDependencies:
                      '@scope/host': '*'
              '';
            }
          ];
        failures = lib.filter (assertion: !assertion.pass) assertions;
        report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;

        packed = pkgs.stdenv.mkDerivation {
          name = "npm-pack-fixture";
          outputs = ["out" "tarball"];
          src = pkgs.runCommand "npm-pack-fixture-source" {} ''
            mkdir "$out"
            printf '%s\n' '{"name":"@scope/fixture","version":"1.0.0","bin":{"fixture":"cli.js"},"files":["cli.js"]}' >"$out/package.json"
            printf '%s\n' '#!/usr/bin/env node' 'console.log("fixture");' >"$out/cli.js"
            printf '%s\n' 'not packed' >"$out/notes.txt"
          '';
          nativeBuildInputs = [pkgs.nodejs_24 (pkgs.callPackage ../../../pkgs/build-support/npm-pack-hook.nix {})];
          buildInputs = [pkgs.nodejs_24];
          installPhase = ''
            runHook preInstall
            install -Dm755 cli.js "$out/lib/cli.js"
            runHook postInstall
          '';
        };
      in {
        checks.npm-packages =
          pkgs.runCommandLocal "npm-packages" {
            inherit report;
            nativeBuildInputs = [pkgs.nodejs_24 pkgs.gitMinimal pkgs.jq pkgs.yq-go pkgs.diffutils];
            passthru.ci.runOnce = true;
          } ''
            if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
            bash ${../../../pkgs/build-support/pnpm-providers.test.bash} ${../../../pkgs/build-support/pnpm-providers.bash}
            bash ${../../../pkgs/build-support/pnpm-lock-updater.test.bash} ${lib.getExe updater} ${lib.getExe updaterWithoutProviders} ${lib.getExe updaterWithLockfiles}
            touch "$out"
          '';

        checks.npm-pack-hook =
          pkgs.runCommandLocal "npm-pack-hook" {
            nativeBuildInputs = [pkgs.diffutils pkgs.gnutar pkgs.gzip];
            passthru.ci.runOnce = true;
          } ''
            set -euo pipefail
            tar -tzf ${packed.tarball}/package.tgz | sort >contents
            printf '%s\n' package/cli.js package/package.json | diff -u - contents

            printf '%s\n' '#!/usr/bin/env node' | diff -u - <(tar -xzOf ${packed.tarball}/package.tgz package/cli.js | head -n 1)
            case "$(head -n 1 ${packed}/lib/cli.js)" in
              '#!/nix/store/'*) ;;
              *) echo 'Fixup must still patch the installed script.' >&2; exit 1 ;;
            esac
            touch "$out"
          '';
      }
    ).checks
