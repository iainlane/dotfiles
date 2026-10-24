{
  pkgs,
  pi ? null,
}:
(pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
  pname = "pi-session-footer";
  version = "0.1.0";
  directory = ./extensions/session-footer;
  npmFlags = ["--ignore-scripts"];
  nativeCheckInputs = [pkgs.gnupatch pkgs.gitMinimal pkgs.python3];
  dontNpmBuild = true;
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;

  passthru.packageRoot = "lib/node_modules/@dotfiles/pi-session-footer";
  PI_TEST_HOST = pkgs.lib.optionalString (pi != null) "${pi}/bin/pi";

  PI_FOOTER_CORE_PATCH = ../../../pkgs/pi-sub-core/reading-metadata.patch;
  PI_FOOTER_CORE_BACKGROUND_PATCH = ../../../pkgs/pi-sub-core/background-refresh.patch;
  PI_FOOTER_CORE_CREDENTIAL_PATCH = ../../../pkgs/pi-sub-core/credential-file.patch;
  PI_FOOTER_TODO_PATCH = ../../../pkgs/rpiv-todo/widget-visibility.patch;

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
}
