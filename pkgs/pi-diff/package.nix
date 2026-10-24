# To update: nix run .#update-pi-diff
{
  autoPatchelfHook,
  buildNpmPackage,
  fetchFromGitHub,
  gitMinimal,
  lib,
  stdenv,
  updaters,
}:
buildNpmPackage {
  pname = "pi-diff";
  version = "0.9.3-unstable-2026-10-24";
  src = fetchFromGitHub {
    owner = "iainlane";
    repo = "pi-diff";
    rev = "39853ae8bf85255f818892d8d8371ff5e5918ad5";
    hash = "sha256-grBGjLTFUegQoBTWGN5l1OR8NtA2JOqCJ2jkQwWLqUQ=";
  };
  npmDepsHash = "sha256-QLO36cXHZMLsuswlhv02FXS6ZMprIYNZIS16nlyizjA=";
  npmFlags = ["--ignore-scripts"];
  npmPackFlags = ["--ignore-scripts"];
  npmPruneFlags = ["--omit=peer"];
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
  nativeCheckInputs = [gitMinimal];
  doCheck = true;
  preCheck = lib.optionalString stdenv.hostPlatform.isLinux ''
    autoPatchelf node_modules/@biomejs/cli-linux-${stdenv.hostPlatform.node.arch}/biome
  '';
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run typecheck
    npm run lint
    npm test
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
