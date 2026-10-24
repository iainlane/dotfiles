{pkgs}:
pkgs.buildNpmPackage {
  pname = "pi-plan-explore";
  version = "0.1.0";
  src = ./extensions/plan-explore;
  npmDeps = pkgs.importNpmLock {npmRoot = ./extensions/plan-explore;};
  inherit (pkgs.importNpmLock) npmConfigHook;
  npmFlags = ["--ignore-scripts"];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/node_modules"
    cp -R "$src"/. "$out/"
    ln -s ${pkgs.pi-subagents}/${pkgs.pi-subagents.packageRoot} "$out/node_modules/pi-subagents"
    runHook postInstall
  '';
}
