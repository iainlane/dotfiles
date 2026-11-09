{
  autoPatchelfHook,
  buildNpmPackage,
  callPackage,
  cctools,
  fetchPnpmDeps,
  importNpmLock,
  jq,
  lib,
  mkShell,
  nodejs,
  pnpm_10,
  pnpmBuildHook,
  pnpmConfigHook,
  srcOnly,
  stdenv,
  updaters,
}:
# A package with a `pnpm-lock.yaml` installs its dependencies with pnpm and
# sets `pnpmDepsHash`. Any other package uses npm and its `package-lock.json`.
{directory, ...} @ args: let
  root = ../.;
  relative = lib.path.removePrefix root directory;
  npmPackages = import ./npm-packages.nix {inherit lib;};
  manifest = lib.importJSON (directory + "/package.json");
  packageRoot = "lib/node_modules/${manifest.name}";
  usesPnpm = builtins.pathExists (directory + "/pnpm-lock.yaml");
  pnpm = args.pnpm or pnpm_10;

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [directory ./typecheck.ts ../.oxlintrc.json ../.oxfmtrc.json];
  };
  sourceRoot = "source/${relative}";

  # The npm and pnpm builds share these attributes. `tsgolint` is the path of
  # Oxlint's type-aware linter binary inside `node_modules`.
  common = {
    finalAttrs,
    tsgolint,
    devShell,
    updateScript,
  }: {
    inherit src sourceRoot;
    nativeBuildInputs = (args.nativeBuildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = (args.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

    preCheck =
      lib.optionalString stdenv.hostPlatform.isLinux ''
        autoPatchelf ${tsgolint}
      ''
      + (args.preCheck or "");

    passthru =
      {
        npmTarball = callPackage ../pkgs/build-support/npm-tarball.nix {} {
          inherit (manifest) name version;
          directory = "${finalAttrs.finalPackage}/${packageRoot}";
        };

        # Entering this shell links the build's `node_modules` into the
        # working tree.
        inherit devShell updateScript;
      }
      // (args.passthru or {});

    meta =
      {
        identifiers.purlParts = npmPackages.purlParts {inherit (manifest) name version;};
      }
      // (args.meta or {});
  };

  npmBuild = let
    deps = callPackage ../pkgs/build-support/npm-deps.nix {} {npmRoot = directory;};
    inherit (deps) npmDeps;
  in
    buildNpmPackage (finalAttrs: let
      shared = common {
        inherit finalAttrs;
        tsgolint = "node_modules/@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint";
        devShell = mkShell {
          packages = [importNpmLock.hooks.linkNodeModulesHook nodejs];
          npmDeps = importNpmLock.buildNodeModules {
            npmRoot = directory;
            inherit nodejs;
            derivationArgs = {inherit npmDeps;};
          };
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
      };
    in
      removeAttrs args ["directory"]
      // shared
      // {
        inherit npmDeps;
        inherit (importNpmLock) npmConfigHook;
        preBuild = deps.verify + (args.preBuild or "");
      });

  pnpmBuild = let
    deps = callPackage ../pkgs/build-support/pnpm-deps.nix {inherit fetchPnpmDeps;} {
      pnpmRoot = directory;
      inherit (args) pname;
      inherit src sourceRoot pnpm;
      hash = args.pnpmDepsHash;
    };
    pnpmHooks = [nodejs pnpm pnpmConfigHook jq nodejs.python] ++ lib.optionals stdenv.hostPlatform.isDarwin [cctools];

    # Run after each `pnpm install`. pnpm 10 runs only the build scripts of
    # the packages in `onlyBuiltDependencies`. node-gyp uses the Node headers
    # from the store instead of downloading them, and
    # `npm_config_build_from_source` makes packages such as node-pty compile
    # their addon instead of loading a bundled prebuilt binary.
    prepare = ''
      ${deps.substitute}
      npm_config_nodedir=${srcOnly nodejs} \
        npm_config_node_gyp=${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js \
        npm_config_build_from_source=true \
        pnpm rebuild
    '';

    nodeModules = stdenv.mkDerivation {
      pname = "${args.pname}-node-modules";
      inherit (args) version;
      inherit src sourceRoot;
      inherit (deps) pnpmDeps;
      nativeBuildInputs = pnpmHooks;
      buildPhase = prepare;
      installPhase = ''
        mkdir "$out"
        cp -a node_modules "$out/"
      '';
      dontFixup = true;
    };
  in
    stdenv.mkDerivation (finalAttrs: let
      shared = common {
        inherit finalAttrs;
        tsgolint = "node_modules/.pnpm/@oxlint-tsgolint+linux-${stdenv.hostPlatform.node.arch}@*/node_modules/@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint";
        devShell = mkShell {
          packages = [importNpmLock.hooks.linkNodeModulesHook nodejs pnpm];
          npmDeps = nodeModules;
        };
        updateScript =
          if deps.provided == []
          then null
          else
            updaters.mkPnpmLockUpdater {
              inherit (args) pname;
              directory = relative;
              packages = deps.provided;
              inherit pnpm;
            };
      };
    in
      removeAttrs args ["directory" "pnpm" "pnpmDepsHash"]
      // shared
      // {
        inherit (deps) pnpmDeps;
        nativeBuildInputs = shared.nativeBuildInputs ++ pnpmHooks ++ [pnpmBuildHook];
        preBuild = prepare + (args.preBuild or "");

        # Install the files that `pnpm pack` would publish, and the production
        # dependencies.
        installPhase =
          args.installPhase or ''
            runHook preInstall

            pnpm pack --pack-destination "$NIX_BUILD_TOP/pack"
            mkdir -p "$out/${packageRoot}"
            tar -xzf "$NIX_BUILD_TOP"/pack/*.tgz --strip-components=1 -C "$out/${packageRoot}"

            # `pnpm install --prod` over the development installation keeps
            # development packages in the virtual store. pnpmConfigHook keeps
            # the store location in the user configuration, which a check phase
            # that changes HOME no longer reads.
            rm -rf node_modules
            pnpm install --offline --prod --frozen-lockfile --ignore-scripts --store-dir="$STORE_PATH"
            ${prepare}
            cp -a node_modules "$out/${packageRoot}/"

            runHook postInstall
          '';
      });
in
  if usesPnpm
  then pnpmBuild
  else npmBuild
