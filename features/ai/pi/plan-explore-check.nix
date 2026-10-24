{pkgs, ...}: {
  pi-plan-explore = pkgs.buildNpmPackage {
    pname = "pi-plan-explore-check";
    version = "0.1.0";
    src = pkgs.lib.fileset.toSource {
      root = ./extensions/plan-explore;
      fileset = pkgs.lib.fileset.unions [
        ./extensions/plan-explore/index.ts
        ./extensions/plan-explore/src
        ./extensions/plan-explore/test
        ./extensions/plan-explore/package.json
        ./extensions/plan-explore/package-lock.json
        ./extensions/plan-explore/tsconfig.json
        ./extensions/plan-explore/.npmrc
      ];
    };
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
    installPhase = ''touch "$out"'';
  };
}
