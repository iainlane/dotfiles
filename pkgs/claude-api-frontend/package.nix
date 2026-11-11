{
  autoPatchelfHook,
  callPackage,
  fetchPnpmDeps,
  lib,
  makeWrapper,
  mkShell,
  nodejs_24,
  openssl,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
  updaters,
}: let
  pnpm = pnpm_10;
  manifest = lib.importJSON ./package.json;
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
in
  assert lib.assertMsg (manifest.packageManager == "pnpm@${pnpm.version}") "The frontend's packageManager must match the Nix pnpm version.";
    stdenv.mkDerivation (finalAttrs: {
      pname = "claude-api-frontend";
      inherit (manifest) version;
      src = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [./. ../../lib/typecheck.ts ../../.oxlintrc.json ../../.oxfmtrc.json];
      };
      sourceRoot = "source/pkgs/claude-api-frontend";

      pnpmDeps = fetchPnpmDeps {
        inherit (finalAttrs) pname version src sourceRoot;
        inherit pnpm;
        fetcherVersion = 3;
        hash = "sha256-p/ODLKgTL3Rrhm37iFW3TWbC44WDYeQTA2fbjPxmF2c=";
      };

      nativeBuildInputs = [makeWrapper nodejs_24 openssl pnpm pnpmConfigHook] ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
      buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
      dontBuild = true;
      doCheck = true;
      __darwinAllowLocalNetworking = true;

      preCheck = lib.optionalString stdenv.hostPlatform.isLinux ''
        autoPatchelf node_modules
      '';
      checkPhase = ''
        runHook preCheck
        pnpm check
        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        checkModules="$TMPDIR/frontend-check-node-modules"
        mv node_modules "$checkModules"
        CI=true pnpm install --prod --offline --frozen-lockfile --ignore-scripts
        mkdir -p "$out/lib/claude-api-frontend"
        cp -r src package.json node_modules "$out/lib/claude-api-frontend/"
        find "$out/lib/claude-api-frontend" -type f \( -name .modules.yaml -o -name .pnpm-workspace-state-v1.json \) -delete
        makeWrapper ${lib.getExe nodejs_24} "$out/bin/claude-api-frontend" \
          --prefix PATH : ${lib.makeBinPath [openssl]} \
          --add-flags "$out/lib/claude-api-frontend/src/cli.ts"
        runHook postInstall
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        for cache in .vite .vitest-cache; do
          if test -e "$out/lib/claude-api-frontend/node_modules/$cache"; then
            printf 'Test cache installed: %s\n' "$cache" >&2
            exit 1
          fi
        done
        rm -rf node_modules
        mv "$checkModules" node_modules
        CLAUDE_API_FRONTEND_PROGRAM="$out/bin/claude-api-frontend" \
          pnpm exec vitest run test/installed.test.ts
        runHook postInstallCheck
      '';

      passthru = {
        npmTarball = callPackage ../build-support/npm-tarball.nix {} {
          inherit (manifest) name version;
          directory = "${finalAttrs.finalPackage}/lib/claude-api-frontend";
        };
        devShell = mkShell {packages = [nodejs_24 openssl pnpm];};
        updateScript = updaters.mkNixUpdateUpdater {
          attr = "claude-api-frontend";
          refresh = true;
          extraFlags = ["--version=skip" "--no-src"];
        };
        maintenance = {
          source = "repository";
          refresh = true;
        };
      };

      meta = {
        description = "Loopback Claude API request conversion before TeamClaude";
        identifiers.purlParts = npmPackages.purlParts {inherit (manifest) name version;};
        mainProgram = "claude-api-frontend";
        platforms = lib.platforms.unix;
      };
    })
