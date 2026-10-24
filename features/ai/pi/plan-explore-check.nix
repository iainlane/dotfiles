{pkgs, ...}: {
  pi-plan-explore = (pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
    pname = "pi-plan-explore-check";
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
    installPhase = ''touch "$out"'';
  };
}
