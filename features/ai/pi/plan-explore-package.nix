{pkgs}:
(pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
  pname = "pi-plan-explore";
  version = "0.1.0";
  directory = ./extensions/plan-explore;

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
    cp -R ${./extensions/plan-explore}/. "$out/"
    ln -s ${pkgs.pi-subagents}/${pkgs.pi-subagents.packageRoot} "$out/node_modules/pi-subagents"
    runHook postInstall
  '';
}
