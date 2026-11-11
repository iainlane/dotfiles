{
  autoPatchelfHook,
  callPackage,
  fetchPnpmDeps,
  lib,
  librechat,
  librechat-code,
  makeWrapper,
  mkShell,
  nodejs_24,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
  updaters,
}: let
  pnpm = pnpm_10;
  manifest = lib.importJSON ./package.json;
  bridge = "${librechat-code}/lib/librechat-code/.build/bridge";
  librechatRoot = "${librechat}/lib/node_modules/LibreChat";
in
  assert lib.assertMsg (manifest.packageManager == "pnpm@${pnpm.version}") "LibreChat's packageManager must match the Nix pnpm version.";
    stdenv.mkDerivation (finalAttrs: {
      pname = "librechat-runtime";
      inherit (manifest) version;
      src = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [./. ../../.oxlintrc.json ../../.oxfmtrc.json];
      };
      sourceRoot = "source/pkgs/librechat-runtime";

      pnpmDeps = fetchPnpmDeps {
        inherit (finalAttrs) pname version src sourceRoot;
        inherit pnpm;
        fetcherVersion = 3;
        hash = "sha256-zabQRxZJGitwigu5RX09RN/unbXPk0Ft4tR6qVic8Ps=";
      };

      nativeBuildInputs = [nodejs_24 pnpm pnpmConfigHook makeWrapper] ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
      buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
      dontStrip = true;
      doCheck = true;
      doInstallCheck = true;
      __darwinAllowLocalNetworking = true;
      LIBRECHAT_CODE_BRIDGE = bridge;
      LIBRECHAT_TEST_ROOT = librechatRoot;

      postUnpack = ''
        ${lib.getExe nodejs_24} source/pkgs/librechat-runtime/scripts/prepare-code-bridge.ts
      '';

      buildPhase = ''
        runHook preBuild
        pnpm build
        runHook postBuild
      '';

      preBuild = lib.optionalString stdenv.hostPlatform.isLinux ''
        autoPatchelf node_modules
      '';

      checkPhase = ''
        runHook preCheck
        pnpm typecheck
        pnpm lint
        pnpm test
        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib" "$out/bin"
        source ${./deploy.bash} "$out/lib/librechat-runtime"
        makeWrapper ${lib.getExe nodejs_24} "$out/bin/librechat-runtime" \
          --add-flags "--disable-wasm-trap-handler $out/lib/librechat-runtime/dist/bin/librechat-runtime.js"
        makeWrapper ${lib.getExe nodejs_24} "$out/bin/librechatctl" \
          --add-flags "--disable-wasm-trap-handler $out/lib/librechat-runtime/dist/bin/librechatctl.js"
        runHook postInstall
      '';

      installCheckPhase = ''
        runHook preInstallCheck
        ${lib.getExe nodejs_24} scripts/check-deployment.ts "$out/lib/librechat-runtime"
        runHook postInstallCheck
      '';

      passthru = {
        tests.deployment = callPackage ./deploy.test.nix {inherit pnpm;};
        updateScript = updaters.mkNixUpdateUpdater {
          attr = "librechat-runtime";
          refresh = true;
          extraFlags = ["--version=skip" "--no-src"];
        };
        maintenance = {
          source = "repository";
          refresh = true;
        };
        devShell = mkShell {
          packages = [nodejs_24 pnpm];
          LIBRECHAT_CODE_BRIDGE = bridge;
          LIBRECHAT_TEST_ROOT = librechatRoot;
        };
      };

      meta = {
        description = "Private LibreChat service and conversation VM controller";
        license = lib.licenses.mit;
        mainProgram = "librechat-runtime";
        platforms = lib.platforms.unix;
      };
    })
