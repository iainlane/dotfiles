{
  callPackage,
  gitMinimal,
  gnupatch,
  pi,
  python3,
}:
(callPackage ../../lib/build-typescript-package.nix {}) {
  pname = "pi-session-footer";
  version = "0.1.0";
  directory = ./.;
  npmFlags = ["--ignore-scripts"];
  nativeCheckInputs = [gnupatch gitMinimal python3];
  dontNpmBuild = true;
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  doCheck = true;

  passthru = {
    packageRoot = "lib/node_modules/@dotfiles/pi-session-footer";
    updateScript = null;
  };
  preCheck = ''
    bash ${pi.setupNativeSdk} "${pi.sdk}/${pi.sdkPackageRoot}"
  '';
  PI_TEST_HOST = "${pi}/bin/pi";

  PI_FOOTER_CORE_PATCH = ../pi-sub-core/reading-metadata.patch;
  PI_FOOTER_CORE_BACKGROUND_PATCH = ../pi-sub-core/background-refresh.patch;
  PI_FOOTER_CORE_CREDENTIAL_PATCH = ../pi-sub-core/credential-file.patch;
  PI_FOOTER_BTW_ISOLATION_PATCH = ../rpiv-btw/session-isolation.patch;
  PI_FOOTER_BTW_RUNTIME_PATCH = ../rpiv-btw/public-runtime.patch;
  PI_FOOTER_TODO_PATCH = ../rpiv-todo/widget-visibility.patch;

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
}
