# Builds a pnpm package from this repository. Local npm packages replace their
# registry releases through pnpm overrides (see `pnpm-deps.nix`), and
# `passthru.devShell` links the same tarballs into the working tree so that
# pnpm works there as usual. The package's own npm tarball is in the `tarball`
# output.
{
  autoPatchelfHook,
  callPackage,
  gitMinimal,
  lib,
  mkShell,
  nodejs_24,
  pnpmConfigHook,
  stdenv,
}: {
  directory,
  pnpm,
  dependencyHashes,
  packageRoot ? null,
  environment ? {},
  shellPackages ? [],
  ...
} @ args: let
  root = ../..;
  relative = lib.removePrefix "./" (lib.path.removePrefix root directory);
  manifest = lib.importJSON (directory + "/package.json");
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  updaters = callPackage ./updaters.nix {};
  npmPackHook = callPackage ./npm-pack-hook.nix {};
  installRoot =
    if packageRoot == null
    then "lib/node_modules/${manifest.name}"
    else packageRoot;
  recipe = removeAttrs args ["directory" "pnpm" "dependencyHashes" "packageRoot" "environment" "shellPackages" "passthru" "meta"];
in
  assert lib.assertMsg (manifest.packageManager == "pnpm@${pnpm.version}") "${relative}: packageManager must match Nix's pnpm version.";
    stdenv.mkDerivation (finalAttrs: let
      deps = callPackage ./pnpm-deps.nix {} {
        npmRoot = directory;
        inherit (finalAttrs) pname src sourceRoot;
        inherit pnpm;
        hash = dependencyHashes.${stdenv.hostPlatform.system};
      };
    in
      {
        inherit (manifest) version;
        src = lib.fileset.toSource {
          inherit root;
          fileset = lib.fileset.unions [directory ../../lib/typecheck.ts ../../.oxlintrc.json ../../.oxfmtrc.json];
        };
        sourceRoot = "source/${relative}";
        inherit (deps) pnpmDeps prePnpmInstall;
        dontStrip = true;
        doCheck = true;

        # The checks run one native program, the type-aware linter. Other
        # prebuilt modules, such as PTY binaries for musl and X11 bindings,
        # need libraries that autoPatchelf cannot satisfy.
        preBuild = lib.optionalString stdenv.hostPlatform.isLinux ''
          tsgolint="$(node --print 'require("node:module").createRequire(require.resolve("oxlint-tsgolint/package.json")).resolve("@oxlint-tsgolint/linux-${stdenv.hostPlatform.node.arch}/tsgolint")')"
          autoPatchelf "$tsgolint"
        '';
        buildPhase = ''
          runHook preBuild
          pnpm run --if-present build
          runHook postBuild
        '';
        checkPhase = ''
          runHook preCheck
          pnpm check
          runHook postCheck
        '';
        # `pnpm deploy` resolves `file:` overrides from its target directory.
        # That directory must start empty, so it has no `.nix-providers`.
        installPhase = ''
          runHook preInstall
          npmPackHook
          mkdir -p "$out/$packageRoot"
          tar -xzf "$tarball/package.tgz" -C "$out/$packageRoot" --strip-components=1
          rm -rf node_modules
          # pnpmConfigHook records the store path in the configuration under
          # HOME. Some check phases change HOME, so pass the store explicitly.
          pnpm install --prod --offline --frozen-lockfile --ignore-scripts --store-dir "$STORE_PATH"
          cp -R node_modules "$out/$packageRoot/"
          rm -f "$out/$packageRoot/node_modules/.pnpm/lock.yaml"
          find "$out/$packageRoot" -type f \( -name .modules.yaml -o -name .pnpm-workspace-state-v1.json \) -delete
          find "$out/$packageRoot" -type d -name .bin -prune -exec rm -r {} +
          runHook postInstall
        '';
      }
      // environment
      // recipe
      // {
        packageRoot = installRoot;
        outputs = ["out" "tarball"];
        nativeBuildInputs = [nodejs_24 pnpm pnpmConfigHook npmPackHook] ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook] ++ (args.nativeBuildInputs or []);
        buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib] ++ (args.buildInputs or []);

        passthru =
          {
            devShell = mkShell (environment
              // {
                packages = [nodejs_24 pnpm gitMinimal] ++ shellPackages;
                shellHook = deps.linkProviders ''"$(git rev-parse --show-toplevel)"/${relative}'';
              });

            npmTarball = "${finalAttrs.finalPackage.tarball}/package.tgz";

            updateScript = updaters.mkPnpmLockUpdater {
              inherit (finalAttrs) pname;
              directory = relative;
              inherit (deps) overrides;
              systems = builtins.attrNames dependencyHashes;
              inherit pnpm;
            };
          }
          // (args.passthru or {});

        meta =
          {
            identifiers.purlParts = npmPackages.purlParts {inherit (manifest) name version;};
          }
          // (args.meta or {});
      })
