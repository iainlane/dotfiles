# To update: nix run .#update-pi-diff
{
  autoPatchelfHook,
  buildNpmPackage,
  fetchFromGitHub,
  gitMinimal,
  lib,
  pi,
  stdenv,
  updaters,
}:
buildNpmPackage {
  pname = "pi-diff";
  version = "0.9.3-unstable-2026-11-04";
  src = fetchFromGitHub {
    owner = "iainlane";
    repo = "pi-diff";
    rev = "b76776ddcf6ad2451f4a83ec8cee65ca37b21222";
    hash = "sha256-1I5fz/DV4pM5VM7xuUiiPMxuafzdIa24MvNX9BQRuZg=";
  };
  patches = [./native-file-renderers.patch];
  npmDepsHash = "sha256-QLO36cXHZMLsuswlhv02FXS6ZMprIYNZIS16nlyizjA=";
  npmFlags = ["--ignore-scripts"];
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
  nativeCheckInputs = [gitMinimal];
  doCheck = true;
  preBuild = ''
    bash ${../../features/ai/pi/scripts/setup-native-sdk.bash} "${pi.sdk}/${pi.sdkPackageRoot}"
  '';
  preCheck = lib.optionalString stdenv.hostPlatform.isLinux ''
    autoPatchelf node_modules/@biomejs/cli-linux-${stdenv.hostPlatform.node.arch}/biome
  '';
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run typecheck
    npm run lint
    npm test -- --maxWorkers=1
    runHook postCheck
  '';
  passthru = {
    packageRoot = "lib/node_modules/@heyhuynhgiabuu/pi-diff";
    updateScript = updaters.mkNixUpdateUpdater {
      attr = "pi-diff";
      extraFlags = ["--version=branch=pi-integration-fixes"];
    };
  };
  meta = {
    description = "Expandable file diffs for Pi edits, writes and codemode";
    homepage = "https://github.com/iainlane/pi-diff";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
