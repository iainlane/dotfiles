{pkgs, ...}: {
  pi-session-footer = pkgs.buildNpmPackage {
    pname = "pi-session-footer-check";
    version = "0.1.0";
    src = pkgs.lib.fileset.toSource {
      root = ./extensions/session-footer;
      fileset = pkgs.lib.fileset.unions [
        ./extensions/session-footer/index.ts
        ./extensions/session-footer/src
        ./extensions/session-footer/test
        ./extensions/session-footer/package.json
        ./extensions/session-footer/package-lock.json
        ./extensions/session-footer/tsconfig.json
        ./extensions/session-footer/vitest.config.ts
        ./extensions/session-footer/.npmrc
      ];
    };
    npmDeps = pkgs.importNpmLock {npmRoot = ./extensions/session-footer;};
    inherit (pkgs.importNpmLock) npmConfigHook;
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
