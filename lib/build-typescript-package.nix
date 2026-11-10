{
  autoPatchelfHook,
  buildNpmPackage,
  callPackage,
  importNpmLock,
  lib,
  mkShell,
  nodejs,
  stdenv,
  updaters,
}: {directory, ...} @ args: let
  root = ../.;
  relative = lib.path.removePrefix root directory;
  npmPackages = import ./npm-packages.nix {inherit lib;};
  manifest = lib.importJSON (directory + "/package.json");
  deps = callPackage ../pkgs/build-support/npm-deps.nix {} {npmRoot = directory;};
  inherit (deps) npmDeps;
in
  buildNpmPackage (finalAttrs:
    removeAttrs args ["directory"]
    // {
      src = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions [directory ./typecheck.ts ../.oxlintrc.json ../.oxfmtrc.json];
      };
      sourceRoot = "source/${relative}";
      inherit npmDeps;
      inherit (importNpmLock) npmConfigHook;
      nativeBuildInputs = (args.nativeBuildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
      buildInputs = (args.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

      preBuild = deps.verify + (args.preBuild or "");

      preCheck =
        lib.optionalString stdenv.hostPlatform.isLinux ''
          autoPatchelf node_modules/@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint
        ''
        + (args.preCheck or "");

      postCheck = ''
        ${args.postCheck or ""}
        rm -rf node_modules/.vite
      '';

      passthru =
        {
          npmTarball = callPackage ../pkgs/build-support/npm-tarball.nix {} {
            inherit (manifest) name version;
            directory = "${finalAttrs.finalPackage}/lib/node_modules/${manifest.name}";
          };

          # Entering this shell links the build's `node_modules` into the
          # working tree.
          devShell = mkShell {
            packages = [importNpmLock.hooks.linkNodeModulesHook nodejs];
            npmDeps = importNpmLock.buildNodeModules {
              npmRoot = directory;
              inherit nodejs;
              derivationArgs = {inherit npmDeps;};
            };
          };

          maintenance = {
            source = "repository";
            refresh = deps.provided != [] && (args.passthru.updateScript or true) != null;
          };
          updateScript =
            if deps.provided == []
            then null
            else
              updaters.mkNpmLockUpdater {
                inherit (args) pname;
                directory = relative;
                packages = deps.provided;
              };
        }
        // (args.passthru or {});

      meta =
        {
          identifiers.purlParts = npmPackages.purlParts {inherit (manifest) name version;};
        }
        // (args.meta or {});
    })
