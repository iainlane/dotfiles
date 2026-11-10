# To update: nix run .#update-pi-diff
{
  autoPatchelfHook,
  buildNpmPackage,
  callPackage,
  fetchFromGitHub,
  gitMinimal,
  importNpmLock,
  lib,
  stdenv,
  updaters,
}: let
  packageLock = lib.importJSON ./npm-deps/package-lock.json;
  deps = callPackage ../build-support/npm-deps.nix {} {
    npmRoot = ./npm-deps;
    inherit packageLock;
    package = packageLock.packages."";
  };
in
  buildNpmPackage {
    pname = "pi-diff";
    version = "0.9.3-unstable-2026-11-10";
    src = fetchFromGitHub {
      owner = "iainlane";
      repo = "pi-diff";
      rev = "a42bc7d49bcbad8cd2d91b45fef15ffdff0efc06";
      hash = "sha256-PGKDRlMEuZ0TJrduB5HAlZtNQLPoSmr1XCBSR5mDegk=";
    };
    inherit (deps) npmDeps;
    inherit (importNpmLock) npmConfigHook;
    npmFlags = ["--ignore-scripts"];
    npmPackFlags = ["--ignore-scripts"];
    npmPruneFlags = ["--omit=peer"];
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    nativeCheckInputs = [gitMinimal];
    doCheck = true;
    preBuild = deps.verify;
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
    postCheck = ''
      rm -rf node_modules/.vite
    '';
    passthru = {
      packageRoot = "lib/node_modules/@heyhuynhgiabuu/pi-diff";
      updateScript = updaters.mkNixUpdateUpdater {
        refresh = true;
        attr = "pi-diff";
        extraFlags = ["--version=branch=pi-integration-fixes"];
        npmLockfile = "pkgs/pi-diff/npm-deps/package-lock.json";
      };
    };
    meta = {
      description = "Expandable file diffs for Pi edits, writes and codemode";
      homepage = "https://github.com/iainlane/pi-diff";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  }
