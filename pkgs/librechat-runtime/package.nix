{
  callPackage,
  lib,
  librechat,
  librechat-code,
  makeWrapper,
  nodejs_24,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "librechat-runtime";
  version = "0.1.0";
  directory = ./.;
  nodejs = nodejs_24;
  nativeBuildInputs = [makeWrapper];

  npmFlags = ["--ignore-scripts"];
  dontStrip = true;
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;
  __darwinAllowLocalNetworking = true;
  LIBRECHAT_TEST_ROOT = "${librechat}/lib/node_modules/LibreChat";
  passthru.updateScript = null;

  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --ignore-scripts --offline --no-audit --no-fund

    mkdir -p "$out/lib/librechat-runtime" "$out/bin"

    cp -R src node_modules package.json "$out/lib/librechat-runtime/"
    cp ${librechat-code}/lib/librechat-code/.build/bridge-worker.mjs "$out/lib/librechat-runtime/src/"

    makeWrapper ${lib.getExe nodejs_24} "$out/bin/librechat-runtime" \
      --add-flags "--disable-wasm-trap-handler $out/lib/librechat-runtime/src/cli.ts"
    runHook postInstall
  '';

  meta = {
    description = "Private LibreChat service and conversation VM controller";
    license = lib.licenses.mit;
    mainProgram = "librechat-runtime";
    platforms = lib.platforms.unix;
  };
}
