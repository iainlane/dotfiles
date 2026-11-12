{
  autoPatchelfHook,
  callPackage,
  diffutils,
  gitMinimal,
  gnutar,
  lib,
  mkShell,
  nodejs_24,
  pi,
  pi-pretty,
  pi-planning,
  pnpm_10,
  pnpmConfigHook,
  runCommandLocal,
  stdenv,
  zstd,
}: let
  manifest = lib.importJSON ./package.json;
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  pnpm = pnpm_10;
  packageRoot = "lib/node_modules/${manifest.name}";
  dependencyHashes = {
    aarch64-darwin = "sha256-ir1Dzd0+CfGaAztqS4Sxf5XQyG4C9tlrU7pLrf/7Tis=";
    aarch64-linux = "sha256-AgrCZ+NkdBiKa8WWTQAN+AHxgwkrR3cQr6kk5Hpn970=";
    x86_64-linux = "sha256-ZynVcwZBUgKftJ3Ib/tDm2nuAGOQWYNLlg3dfSOpNxE=";
  };
  updaters = callPackage ../build-support/updaters.nix {};
in
  assert lib.assertMsg (manifest.packageManager == "pnpm@${pnpm.version}") "The footer's packageManager must match Nix's pnpm version.";
    stdenv.mkDerivation (finalAttrs: let
      dependencyArgs = {
        npmRoot = ./.;
        pname = "pi-session-footer";
        inherit (finalAttrs) src sourceRoot;
        inherit pnpm;
        hash = dependencyHashes.${stdenv.hostPlatform.system};
      };
      deps = callPackage ../build-support/pnpm-deps.nix {} dependencyArgs;
    in {
      pname = "pi-session-footer";
      inherit (manifest) version;
      src = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [./. ../../.oxlintrc.json ../../.oxfmtrc.json];
      };
      sourceRoot = "source/pkgs/pi-session-footer";
      inherit (deps) pnpmDeps;
      nativeBuildInputs = [nodejs_24 pnpm pnpmConfigHook gitMinimal] ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
      buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
      __darwinAllowLocalNetworking = true;
      dontStrip = true;
      doCheck = true;
      doInstallCheck = true;
      prePnpmInstall = deps.prepare;
      preBuild = lib.optionalString stdenv.hostPlatform.isLinux ''
        tsgolint="$(node --print 'require("node:module").createRequire(require.resolve("oxlint-tsgolint/package.json")).resolve("@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint")')"
        autoPatchelf "$tsgolint"
      '';
      buildPhase = ''
        runHook preBuild
        pnpm typecheck
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        pnpm check
        runHook postCheck
      '';
      PI_TEST_HOST = "${pi}/bin/pi";
      PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
      PI_TEST_PLANNING = "${pi-planning}/${pi-planning.packageRoot}";
      installPhase = ''
        runHook preInstall
        # Deploy beside the source: pnpm 10 retains source-relative archive paths.
        chmod u+w ..
        deployment="$(mktemp -d ../footer-deploy.XXXXXX)"
        pnpm --filter ${manifest.name} deploy --prod --offline --frozen-lockfile --ignore-scripts --ignore-pnpmfile "$deployment"
        cp package.json "$deployment/package.json"
        mkdir -p "$(dirname "$out/${packageRoot}")"
        mv "$deployment" "$out/${packageRoot}"
        rm -f "$out/${packageRoot}/pnpm-lock.yaml" "$out/${packageRoot}/node_modules/.pnpm/lock.yaml"
        find "$out/${packageRoot}" -type f \( -name .modules.yaml -o -name .pnpm-workspace-state-v1.json \) -delete
        find "$out/${packageRoot}" -type d -name .bin -prune -exec rm -r {} +
        runHook postInstall
      '';
      installCheckPhase = ''
        runHook preInstallCheck
        node scripts/check-deployment.ts "$out/${packageRoot}"
        runHook postInstallCheck
      '';
      passthru = {
        inherit packageRoot;
        devDependencies = finalAttrs.finalPackage.overrideAttrs {
          pname = "pi-session-footer-dev-dependencies";
          doCheck = false;
          doInstallCheck = false;
          dontFixup = true;
          buildPhase = "runHook preBuild";
          installPhase = ''
            mkdir -p "$out"
            cp -a node_modules "$out/"
          '';
        };
        npmTarball = callPackage ../build-support/npm-tarball.nix {} {
          inherit (manifest) name version;
          directory = "${finalAttrs.finalPackage}/${packageRoot}";
        };
        devShell = mkShell {
          packages = [nodejs_24 pnpm gitMinimal];
          inherit (finalAttrs) PI_TEST_HOST PI_TEST_PRETTY PI_TEST_PLANNING;
          shellHook = ''
            footerDirectory="$(git rev-parse --show-toplevel)/pkgs/pi-session-footer"
            if [ -e "$footerDirectory/node_modules" ] && [ ! -L "$footerDirectory/node_modules" ]; then
              echo 'Move the existing footer node_modules directory before using the Nix dependency shell.' >&2
              return 1
            fi
            ln -sfn ${finalAttrs.finalPackage.devDependencies}/node_modules "$footerDirectory/node_modules"
          '';
        };
        tests.dependency-cache = let
          changedProviders =
            callPackage ../build-support/pnpm-deps.nix {
              localNpmPackages = {};
              fetchPnpmDeps = _: deps.pnpmDeps;
            }
            dependencyArgs;
        in
          runCommandLocal "pi-session-footer-dependency-cache" {
            nativeBuildInputs = [gnutar zstd diffutils];
            passthru.ci.runOnce = true;
          } ''
            set -euo pipefail
            cp ${./pnpm-lock.yaml} pnpm-lock.yaml
            ${deps.prepare}

            cp ${./pnpm-lock.yaml} pnpm-lock.yaml
            printf '\n' >> pnpm-lock.yaml
            if (${deps.prepare}) > stale-lock.log 2>&1; then
              echo 'A changed portable lock must invalidate the cached graph.' >&2
              exit 1
            fi
            grep -Fx 'The pnpm lockfile changed. Update the pnpm dependency hash.' stale-lock.log

            cp ${./pnpm-lock.yaml} pnpm-lock.yaml
            if (${changedProviders.prepare}) > stale-providers.log 2>&1; then
              echo 'Changed local providers must invalidate the cached graph.' >&2
              exit 1
            fi
            grep -Fx 'Local npm packages changed. Update the pnpm dependency hash.' stale-providers.log
            touch "$out"
          '';
        updateScript = updaters.mkPnpmLockUpdater {
          pname = "pi-session-footer";
          directory = "pkgs/pi-session-footer";
          packages = deps.provided;
          systems = builtins.attrNames dependencyHashes;
          inherit pnpm;
        };
      };
      meta.identifiers.purlParts = npmPackages.purlParts {inherit (manifest) name version;};
    })
