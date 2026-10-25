{pkgs, ...}: {
  pi-session-footer = (pkgs.callPackage ../../../lib/build-typescript-package.nix {}) {
    pname = "pi-session-footer-check";
    version = "0.1.0";
    directory = ./extensions/session-footer;
    npmFlags = ["--ignore-scripts"];
    nativeBuildInputs = [pkgs.gnupatch pkgs.gitMinimal pkgs.python3];
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
    installPhase = ''touch "$out"'';
  };
}
