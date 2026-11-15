{lib, ...}: let
  npmPackages = import ../../../lib/npm-packages.nix {inherit lib;};

  producer = name: version: {
    meta.identifiers.purlParts = npmPackages.purlParts {inherit name version;};
    npmTarball = "/nix/store/${name}.tgz";
  };
  host = producer "@scope/host" "2.0.0";
  linked = producer "linked" "1.0.0";
  consumer =
    producer "@dotfiles/consumer" "1.0.0"
    // {
      npmRuntimeDependencies = {
        "@dotfiles/private" = "^0.1.0";
        other = "^4";
      };
    };
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
        # `nix build .#<attribute>.tarball` packs `$FAKE_PACKAGES/<attribute>`
        # into `$FAKE_STORE/<attribute>-tarball/package.tgz`.
        nix = pkgs.writeShellApplication {
          name = "nix";
          runtimeInputs = [pkgs.gnutar pkgs.gzip];
          text = ''
            if (($# != 4)) || [[ "$1 $2 $3" != "build --no-link --print-out-paths" || "$4" != .#*.tarball ]]; then
              echo "The fake nix does not support: $*" >&2
              exit 1
            fi
            attribute="''${4#.#}"
            attribute="''${attribute%.tarball}"
            output="$FAKE_STORE/$attribute-tarball"
            mkdir -p "$output"
            tar -czf "$output/package.tgz" -C "$FAKE_PACKAGES" --transform "s|^$attribute|package|" "$attribute"
            printf '%s\n' "$output"
          '';
        };
        # Writes the SHA-256 of the package's pnpm-lock.yaml as its
        # `dependencyHash`.
        nix-update = pkgs.writeShellApplication {
          name = "nix-update";
          runtimeInputs = [pkgs.coreutils pkgs.gnused];
          text = ''
            file=""
            while (($# > 0)); do
              if [[ "$1" == --override-filename ]]; then
                file="$2"
              fi
              shift
            done
            hash="$(sha256sum "$(dirname "$file")/pnpm-lock.yaml" | cut -d ' ' -f 1)"
            sed -i -E "s|dependencyHash = \"[^\"]*\";|dependencyHash = \"sha256-$hash\";|" "$file"
          '';
        };
        updaters = pkgs.callPackage ../../../pkgs/build-support/updaters.nix {
          inherit nix nix-update;
        };
        pnpm = pkgs.writeShellApplication {
          name = "pnpm";
          runtimeInputs = [pkgs.python3 pkgs.yq-go];
          text = ''exec python3 ${../../../pkgs/build-support/fake-pnpm.py} "$@"'';
        };
        updater = updaters.mkPnpmLockUpdater {
          pname = "scenario";
          directory = "scenario";
          catalogue = npmPackages.pnpmCatalogue ({
              inherit consumer host linked;
              private = producer "@dotfiles/private" "0.1.0";
            }
            // lib.genAttrs (map (count: "chain-${toString count}") (lib.range 0 9)) (name: producer name "1.0.0"));
          inherit pnpm;
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
              name = "the pnpm catalogue lists each npm package with its tarball name, the installable that builds the tarball and its runtime dependencies";
              pass =
                npmPackages.pnpmCatalogue {inherit consumer host github plain;}
                == [
                  {
                    name = "@dotfiles/consumer";
                    version = "1.0.0";
                    file = "dotfiles-consumer-1.0.0.tgz";
                    installable = ".#consumer.tarball";
                    dependencies = {
                      "@dotfiles/private" = "^0.1.0";
                      other = "^4";
                    };
                  }
                  {
                    name = "@scope/host";
                    version = "2.0.0";
                    file = "scope-host-2.0.0.tgz";
                    installable = ".#host.tarball";
                    dependencies = {};
                  }
                ];
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
            nativeBuildInputs = [pkgs.nodejs_24 pkgs.gitMinimal pkgs.jq pkgs.yq-go pkgs.diffutils pkgs.pyright pkgs.ruff];
            passthru.ci.runOnce = true;
          } ''
            if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
            ruff check ${../../../pkgs/build-support/fake-pnpm.py}
            ruff format --check ${../../../pkgs/build-support/fake-pnpm.py}
            pyright ${../../../pkgs/build-support/fake-pnpm.py}
            bash ${../../../pkgs/build-support/pnpm-providers.test.bash} ${../../../pkgs/build-support/pnpm-providers.bash}
            bash ${../../../pkgs/build-support/pnpm-lock-updater.test.bash} ${lib.getExe updater}
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
