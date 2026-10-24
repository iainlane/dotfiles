{
  pkgs,
  pi ? null,
}: let
  packageRoot = "lib/node_modules/@dotfiles/pi-planning";
in
  (pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
    pname = "pi-planning";
    version = "0.1.0";
    directory = ./extensions/planning;

    npmFlags = ["--ignore-scripts"];
    dontNpmBuild = true;
    npmPackFlags = ["--ignore-scripts"];
    npmPruneFlags = ["--omit=peer"];
    doCheck = true;
    passthru = {inherit packageRoot;};
    postInstall = ''
      ln -s ${pkgs.pi-subagents}/${pkgs.pi-subagents.packageRoot} "$out/${packageRoot}/node_modules/pi-subagents"
    '';
    PI_TEST_HOST = pkgs.lib.optionalString (pi != null) "${pi}/bin/pi";
    checkPhase = ''
      runHook preCheck
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      npm run check
      runHook postCheck
    '';
  }
