{
  callPackage,
  pi,
  pi-diff,
  pi-pretty,
  pi-subagents,
}: let
  packageRoot = "lib/node_modules/@dotfiles/pi-planning";
in
  (callPackage ../../lib/build-typescript-package.nix {}) {
    pname = "pi-planning";
    version = "0.1.0";
    directory = ./.;

    npmFlags = ["--ignore-scripts"];
    dontNpmBuild = true;
    npmPackFlags = ["--ignore-scripts"];
    npmPruneFlags = ["--omit=peer"];
    doCheck = true;
    passthru = {
      inherit packageRoot;
      updateScript = null;
    };
    postInstall = ''
      ln -s ${pi-subagents}/${pi-subagents.packageRoot} "$out/${packageRoot}/node_modules/pi-subagents"
    '';
    preCheck = ''
      bash ${pi.setupNativeSdk} "${pi.sdk}/${pi.sdkPackageRoot}"
    '';
    PI_TEST_HOST = "${pi}/bin/pi";
    PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
    PI_TEST_DIFF = "${pi-diff}/${pi-diff.packageRoot}";
    PI_TEST_SUBAGENTS = "${pi-subagents}/${pi-subagents.packageRoot}";
    checkPhase = ''
      runHook preCheck
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      npm run check
      runHook postCheck
    '';
  }
