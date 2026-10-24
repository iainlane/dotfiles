{pkgs}:
(pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
  pname = "pi-integration-tests";
  version = "0.1.0";
  directory = ./test;

  npmFlags = ["--ignore-scripts"];
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;
  passthru.packageRoot = "lib/node_modules/@dotfiles/pi-integration-tests";
  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';
}
