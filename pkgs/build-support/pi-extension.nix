# The shared builder for the Pi extensions packaged under `pkgs/`. Each
# extension's `package.nix` calls it with `callPackage`.
#
# The source is the published registry tarball. It contains the built
# extension and no lockfile, so `nix run .#update-<name>` resolves one from the
# tarball's manifest and writes it to `npm-deps/`, alongside the pin in
# `source.json`.
#
# `./project-pi-npm-package.nix` adapts that lockfile for `importNpmLock`,
# which resolves `node_modules` from the integrity hashes it records.
{
  buildNpmPackage,
  fetchurl,
  importNpmLock,
  lib,
  stdenv,
  updaters,
  # The npm package name, scope included.
  npmName,
  # The version and tarball hash, in the file the updater rewrites.
  source,
  # The directory holding the lockfile.
  npmRoot,
  # `meta.description`, which the lockfile does not record.
  description,
  # Inputs for an extension with a dependency that compiles against a system
  # library, which `npm rebuild` builds during the configure phase.
  nativeBuildInputs ? [],
  buildInputs ? [],
  # Replacement version ranges for the updater to apply to the manifest
  # before it resolves the lockfile. Use one when a dependency's declared
  # range admits a version the extension cannot use.
  npmDependencies ? {},
}: let
  pin = lib.importJSON source;

  # `overlays/local-pkgs.nix` derives each package's attribute from its
  # directory, so a scoped extension is packaged under its basename alone.
  pname = lib.last (lib.splitString "/" npmName);

  packageLock = lib.importJSON (npmRoot + "/package-lock.json");

  # The lockfile's root record carries the manifest fields npm resolves
  # against, which is everything the build and the projection need.
  manifest = packageLock.packages."";

  license = lib.getLicenseFromSpdxIdOr (manifest.license or "") null;

  # Pi loads an extension from the directory holding its `package.json`, which
  # `npmInstallHook` names after the scoped npm name.
  packageRoot = "lib/node_modules/${npmName}";

  projected = import ./project-pi-npm-package.nix {inherit lib;} {
    package = manifest;
    inherit packageLock;
  };
in
  buildNpmPackage {
    inherit pname nativeBuildInputs buildInputs;
    inherit (pin) version;

    src = fetchurl {
      url = "https://registry.npmjs.org/${npmName}/-/${pname}-${pin.version}.tgz";
      hash = pin.tarballHash;
    };

    # The npm tarball layout puts everything under `package/`.
    sourceRoot = "package";

    npmDeps = importNpmLock {
      inherit npmRoot;
      inherit (projected) package packageLock;
    };

    inherit (importNpmLock) npmConfigHook;

    # The extension is installed prebuilt, so its dev tree is unused, and
    # omitting optional dependencies keeps platform-specific native binaries
    # out, making the result identical on every system.
    npmInstallFlags = [
      "--omit=dev"
      "--omit=optional"
    ];

    dontNpmBuild = true;

    # The manifest keeps its dev dependencies, so a prune resolves them and
    # tries to fetch what the install omitted. Nothing needs pruning: the dev
    # tree was never installed.
    dontNpmPrune = true;

    # `npmInstallHook` lists the files to install with `npm pack --dry-run`,
    # which runs `prepack`. That rebuilds the extension with tools the install
    # omits, and its output is in the tarball already.
    npmPackFlags = ["--ignore-scripts"];

    # `buildNpmPackage` turns stripping off as too slow for a typical
    # node_modules tree. A native addon has to be stripped: its debug
    # information names the `-dev` output of every library it was compiled
    # against, which would otherwise stay in the runtime closure.
    dontStrip = false;

    # ld records a fresh UUID in each Mach-O it links, so the addon differs
    # between two builds of the same source.
    env.NIX_LDFLAGS = lib.optionalString stdenv.hostPlatform.isDarwin "-no_uuid";

    # With the dev tree omitted, an extension whose dependencies are all dev
    # installs no node_modules, and `npmInstallHook` copies that directory
    # without checking it exists. Creating the destination first makes the hook
    # skip the copy.
    preInstall = lib.optionalString (manifest.dependencies or {} == {}) ''
      mkdir -p $out/${packageRoot}/node_modules
    '';

    postInstall = ''
      # Remove build artifacts that bloat the closure: node-gyp's leavings
      # contain absolute paths to the compiler, the SDK and the `-dev` outputs
      # it built against. `gyp-mac-tool`, which gyp writes on Darwin only, is a
      # Python script whose patched shebang pulls in python3.
      find $out/lib/node_modules \( \
        -name config.gypi \
        -o -name .deps \
        -o -name '*Makefile' \
        -o -name '*.target.mk' \
        -o -name gyp-mac-tool \
      \) -exec rm -r {} +

      # Loading the addon does not need the object files it was compiled from,
      # and the empty archive beside them records a timestamp that changes
      # between builds.
      find $out/lib/node_modules -path '*/build/Release/*' \
        \( -name '*.o' -o -name '*.a' \) -delete

      find $out/lib/node_modules -type d -empty -delete
    '';

    passthru = {
      inherit packageRoot;

      updateScript = updaters.mkPiExtensionUpdater {
        inherit npmName pname npmDependencies;
      };
    };

    meta =
      {
        inherit description;
        homepage = "https://www.npmjs.com/package/${npmName}";
        platforms = lib.platforms.unix;
      }
      // lib.optionalAttrs (license != null) {
        inherit license;
      };
  }
