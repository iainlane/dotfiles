{
  callPackage,
  lib,
  nodejs_24,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "librechat-runtime";
  version = "0.1.0";
  directory = ./.;
  nodejs = nodejs_24;
  npmFlags = ["--ignore-scripts"];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;
  passthru.updateScript = null;

  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/librechat-runtime"
    cp *.ts package.json "$out/lib/librechat-runtime/"
    runHook postInstall
  '';

  meta = {
    description = "Private LibreChat service and conversation VM controller";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
