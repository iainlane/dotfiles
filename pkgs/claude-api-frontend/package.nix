{
  callPackage,
  lib,
  makeWrapper,
  nodejs_24,
  openssl,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "claude-api-frontend";
  version = "0.1.0";
  directory = ./.;
  nodejs = nodejs_24;
  nativeBuildInputs = [makeWrapper openssl];
  npmFlags = ["--ignore-scripts"];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;
  __darwinAllowLocalNetworking = true;
  passthru.updateScript = null;

  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --ignore-scripts --offline --no-audit --no-fund
    mkdir -p "$out/lib/claude-api-frontend"
    cp -r src package.json node_modules "$out/lib/claude-api-frontend/"
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/claude-api-frontend" \
      --prefix PATH : ${lib.makeBinPath [openssl]} \
      --add-flags "$out/lib/claude-api-frontend/src/cli.ts"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test "$(PATH="" "$out/bin/claude-api-frontend" --version)" = 0.1.0
    PATH="" "$out/bin/claude-api-frontend" --help
    runHook postInstallCheck
  '';

  meta = {
    description = "Loopback Claude API request conversion before TeamClaude";
    mainProgram = "claude-api-frontend";
    platforms = lib.platforms.unix;
  };
}
