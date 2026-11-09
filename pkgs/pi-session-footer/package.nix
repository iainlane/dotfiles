{
  callPackage,
  fetchPnpmDeps,
  gitMinimal,
  pi,
  pi-pretty,
  pi-planning,
  pnpmConfigHook,
  pnpm_10,
}:
(callPackage ../../lib/build-typescript-package.nix {inherit fetchPnpmDeps pnpmConfigHook pnpm_10;}) {
  pname = "pi-session-footer";
  version = "0.1.0";
  directory = ./.;
  pnpmDepsHash = "sha256-jgSVgVoujWlH7Vn/KiQr1XAxuzLVpAhkCJG2h6lIfGk=";
  nativeCheckInputs = [gitMinimal];
  dontPnpmBuild = true;
  doCheck = true;
  __darwinAllowLocalNetworking = true;

  passthru.packageRoot = "lib/node_modules/@dotfiles/pi-session-footer";
  PI_TEST_HOST = "${pi}/bin/pi";
  PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
  PI_TEST_PLANNING = "${pi-planning}/${pi-planning.packageRoot}";

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    pnpm check
    runHook postCheck
  '';
}
