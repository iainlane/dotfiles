{
  callPackage,
  pi,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "pi-integration-tests";
  version = "0.1.0";
  directory = ./.;

  npmFlags = ["--ignore-scripts"];
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;
  preBuild = ''
    bash ${pi.setupNativeSdk} "${pi.sdk}/${pi.sdkPackageRoot}"
  '';
  passthru = {
    packageRoot = "lib/node_modules/@dotfiles/pi-integration-tests";
    updateScript = null;
  };
  checkPhase = ''
    runHook preCheck
    npm run check
    runHook postCheck
  '';
}
