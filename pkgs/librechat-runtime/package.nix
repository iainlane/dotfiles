{
  callPackage,
  lib,
  librechat,
  librechat-code,
  makeWrapper,
  nodejs_24,
  pnpm_10,
}: let
  pnpm = pnpm_10;
  environment = {
    LIBRECHAT_CODE_BRIDGE = "${librechat-code}/lib/librechat-code/.build/bridge";
    LIBRECHAT_TEST_ROOT = "${librechat}/lib/node_modules/LibreChat";
  };
in
  (callPackage ../build-support/pnpm-package.nix {}) {
    pname = "librechat-runtime";
    directory = ./.;
    inherit pnpm environment;
    dependencyHashes = {
      aarch64-darwin = "sha256-712SnaZPtg4jZ9e8NaA9Az/Y7XU2SQZA9kC0egRhuHo=";
      aarch64-linux = "sha256-712SnaZPtg4jZ9e8NaA9Az/Y7XU2SQZA9kC0egRhuHo=";
      x86_64-linux = "sha256-712SnaZPtg4jZ9e8NaA9Az/Y7XU2SQZA9kC0egRhuHo=";
    };
    packageRoot = "lib/librechat-runtime";
    # The workspace root is not an npm package.
    npmTarball = false;

    nativeBuildInputs = [makeWrapper];
    doInstallCheck = true;
    __darwinAllowLocalNetworking = true;

    postUnpack = ''
      ${lib.getExe nodejs_24} source/pkgs/librechat-runtime/scripts/prepare-code-bridge.ts
    '';

    checkPhase = ''
      runHook preCheck
      pnpm typecheck
      pnpm lint
      pnpm test --maxWorkers=1
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$out/bin"
      source ${./deploy.bash} "$out/$packageRoot"
      makeWrapper ${lib.getExe nodejs_24} "$out/bin/librechat-runtime" \
        --add-flags "--disable-wasm-trap-handler $out/$packageRoot/dist/bin/librechat-runtime.js"
      makeWrapper ${lib.getExe nodejs_24} "$out/bin/librechatctl" \
        --add-flags "--disable-wasm-trap-handler $out/$packageRoot/dist/bin/librechatctl.js"
      runHook postInstall
    '';

    installCheckPhase = ''
      runHook preInstallCheck
      node scripts/check-deployment.ts "$out/$packageRoot"
      runHook postInstallCheck
    '';

    passthru.tests.deployment = callPackage ./deploy.test.nix {inherit pnpm;};

    meta = {
      description = "Private LibreChat service and conversation VM controller";
      license = lib.licenses.mit;
      mainProgram = "librechat-runtime";
      platforms = lib.platforms.unix;
    };
  }
