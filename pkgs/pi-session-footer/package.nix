{
  callPackage,
  gitMinimal,
  pi,
  pi-pretty,
  pi-planning,
  python3,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "pi-session-footer";
  version = "0.1.0";
  directory = ./.;
  npmFlags = ["--ignore-scripts"];
  nativeCheckInputs = [
    gitMinimal
    python3
  ];
  dontNpmBuild = true;
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;

  passthru.packageRoot = "lib/node_modules/@dotfiles/pi-session-footer";
  PI_TEST_HOST = "${pi}/bin/pi";
  PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
  PI_TEST_PLANNING = "${pi-planning}/${pi-planning.packageRoot}";

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
}
