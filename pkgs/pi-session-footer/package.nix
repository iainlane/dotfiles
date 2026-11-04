{
  callPackage,
  gitMinimal,
  pi,
  python3,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "pi-session-footer";
  version = "0.1.0";
  directory = ./.;
  npmFlags = ["--ignore-scripts"];
  nativeCheckInputs = [gitMinimal python3];
  dontNpmBuild = true;
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;

  passthru.packageRoot = "lib/node_modules/@dotfiles/pi-session-footer";
  PI_TEST_HOST = "${pi}/bin/pi";

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
}
