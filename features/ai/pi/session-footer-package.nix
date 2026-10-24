{pkgs}:
pkgs.buildNpmPackage {
  pname = "pi-session-footer";
  version = "0.1.0";
  src = ./extensions/session-footer;
  npmDeps = pkgs.importNpmLock {npmRoot = ./extensions/session-footer;};
  inherit (pkgs.importNpmLock) npmConfigHook;
  npmFlags = ["--ignore-scripts"];
  nativeCheckInputs = [pkgs.gnupatch pkgs.gitMinimal pkgs.python3];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;

  PI_FOOTER_CORE_PATCH = ../../../pkgs/pi-sub-core/reading-metadata.patch;
  PI_FOOTER_TODO_PATCH = ../../../pkgs/rpiv-todo/widget-visibility.patch;

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/node_modules"
    cp -R "$src"/. "$out/"
    ln -s ${pkgs.pi-prs}/${pkgs.pi-prs.packageRoot} "$out/node_modules/pi-prs"
    runHook postInstall
  '';
}
