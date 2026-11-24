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
  lockfile = ./npm-deps/package-lock.json;
  packageLock = lib.importJSON lockfile;
  devDependencies = packageLock.packages."".devDependencies;
  piDevDependencies = lib.filterAttrs (name: _: lib.hasPrefix "@earendil-works/" name) devDependencies;
  deps = callPackage ../build-support/npm-deps.nix {} {
    npmRoot = ./npm-deps;
    inherit packageLock;
    package = packageLock.packages."";
  };
in
  buildNpmPackage {
    pname = "pi-diff";
    version = "0.9.3-unstable-2026-11-16";
    src = fetchFromGitHub {
      owner = "iainlane";
      repo = "pi-diff";
      rev = "79b3d876ae4e64d7a5d0a080123de5ec2350f158";
      hash = "sha256-3ivm6CT+CL0ek/51x+Eq5lOztOjyH+XM6JhCFRf4twU=";
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
    # The development graph must match the Pi tarball used in the build.
    postPatch = ''
      npm pkg set ${lib.escapeShellArgs (lib.mapAttrsToList (name: version: "devDependencies.${name}=${version}") piDevDependencies)}
      cp ${lockfile} package-lock.json
      substituteInPlace src/rendering/tool-renderers.ts \
        --replace-fail 'override render(width: number): string[]' \
                       'override render(width: number): readonly string[]'
    '';
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
