# The shared builder for the Pi extensions packaged under `pkgs/`. Each
# extension's `package.nix` calls it with `callPackage`.
#
# An extension is an npm package, so building one means resolving its
# dependencies to exact versions. `importNpmLock` does that from a
# `package-lock.json`, which pairs every dependency with a version and an
# integrity hash, so each package under `pkgs/` commits one in `npm-deps/`.
#
# Where that lockfile comes from decides the dependency versions of the
# extension, and there are two cases. `source.json` records which
# one applies, and `nix run .#update-<name>` rewrites it and the lockfile
# together.
#
# A project that tags its releases and commits a lockfile has already published
# the versions that it tested against. For those, the build takes its source
# from the release tag and the updater copies the lockfile out of it unchanged.
#
# The rest are built from the published registry tarball, because npm removes
# `package-lock.json` when it packs one. With no lockfile to copy, the updater
# resolves the manifest's version ranges itself and takes the newest version
# that each range allowed on the day of the run.
#
# Either lockfile then passes through `./project-pi-npm-package.nix`, which
# removes the records npm writes with a `resolved` URL but no `integrity` hash.
# `importNpmLock` cannot verify a dependency without a hash, so it fails on
# such a record.
{
  buildNpmPackage,
  fetchFromGitHub,
  fetchurl,
  importNpmLock,
  jq,
  lib,
  updaters,
  # The npm package name, scope included.
  npmName,
  # The pin that the updater rewrites: a version, and either a GitHub tag and tree
  # hash or the registry tarball's hash.
  source,
  # The directory containing the lockfile.
  npmRoot,
  # `{owner, repo}` for a package built from a GitHub release tag, or null to
  # build from the registry tarball. `tagPrefix` is what the tag puts before
  # the version; a monorepo usually puts the package name there.
  gitHub ? null,
  tagPrefix ? "v",
  # `meta.description`, which the lockfile does not record.
  description,
  # Replacement version ranges for the updater to apply to the manifest
  # before it resolves the lockfile. Use one when a dependency's declared
  # range admits a version the extension cannot use. Only a registry-tarball
  # package needs this: a GitHub source takes upstream's own resolution.
  npmDependencies ? {},
  # A native binary reaches npm as one package per platform, listed as the
  # optional dependencies of a wrapper package. npm installs whichever one
  # matches the machine running the install, so keeping them ties the result to
  # the system that built it.
  #
  # Most extensions are TypeScript, which Pi loads directly, so the default
  # omits them and every system gets the same output. Set this false for an
  # extension that does not work without its binary.
  omitOptional ? true,
}: let
  pin = lib.importJSON source;

  # `overlays/local-pkgs.nix` derives each package's attribute from its
  # directory, so a scoped extension is packaged under its basename alone.
  pname = lib.last (lib.splitString "/" npmName);

  packageLock = lib.importJSON (npmRoot + "/package-lock.json");

  # The lockfile's root record repeats the manifest fields npm resolves
  # against, which is everything the build and the projection need.
  manifest = packageLock.packages."";

  license = lib.getLicenseFromSpdxIdOr (manifest.license or "") null;

  # Pi loads an extension from the directory containing its `package.json`.
  # `npmInstallHook` installs that directory under the scoped npm name.
  packageRoot = "lib/node_modules/${npmName}";

  projected = import ./project-pi-npm-package.nix {inherit lib;} {
    package = manifest;
    inherit packageLock;
  };
in
  buildNpmPackage ({
      inherit pname;
      inherit (pin) version;

      nativeBuildInputs = lib.optional (npmDependencies != {}) jq;

      # The updater applied `npmDependencies` to the manifest it resolved, so
      # the lockfile already accounts for them. npm installs from the manifest
      # in the source, though, which still declares what upstream declared, so
      # apply the same edit here for the two to agree.
      postPatch = lib.optionalString (npmDependencies != {}) ''
        jq --argjson deps ${lib.escapeShellArg (builtins.toJSON npmDependencies)} \
          --from-file ${./promote-npm-dependencies.jq} \
          package.json >package.json.new
        mv package.json.new package.json
      '';

      src =
        if gitHub != null
        then
          fetchFromGitHub {
            inherit (gitHub) owner repo;
            inherit (pin) hash;
            tag = "${tagPrefix}${pin.version}";
          }
        else
          fetchurl {
            url = "https://registry.npmjs.org/${npmName}/-/${pname}-${pin.version}.tgz";
            hash = pin.tarballHash;
          };

      npmDeps = importNpmLock {
        inherit npmRoot;
        inherit (projected) package packageLock;
      };

      inherit (importNpmLock) npmConfigHook;

      # The extension is installed prebuilt, so nothing needs its dev tree.
      npmInstallFlags =
        ["--omit=dev"]
        ++ lib.optional omitOptional "--omit=optional";

      dontNpmBuild = true;

      # The manifest keeps its dev dependencies, so a prune resolves them and
      # tries to fetch what the install omitted. Nothing needs pruning: the dev
      # tree was never installed.
      dontNpmPrune = true;

      # `npmInstallHook` lists the files to install with `npm pack --dry-run`,
      # which runs `prepack`. That rebuilds the extension with tools the install
      # omits, and its output is in the tarball already.
      npmPackFlags = ["--ignore-scripts"];

      # With the dev tree omitted, an extension whose dependencies are all dev
      # installs no node_modules, and `npmInstallHook` copies that directory
      # without checking it exists. Creating the destination first makes the hook
      # skip the copy.
      preInstall = lib.optionalString (manifest.dependencies or {} == {}) ''
        mkdir -p $out/${packageRoot}/node_modules
      '';

      passthru = {
        inherit packageRoot;

        updateScript = updaters.mkPiExtensionUpdater {
          inherit npmName pname npmDependencies gitHub tagPrefix;
        };
      };

      meta =
        {
          inherit description;
          homepage =
            if gitHub != null
            then "https://github.com/${gitHub.owner}/${gitHub.repo}"
            else "https://www.npmjs.com/package/${npmName}";
          platforms = lib.platforms.unix;
        }
        // lib.optionalAttrs (license != null) {
          inherit license;
        };
    }
    // lib.optionalAttrs (gitHub == null) {
      # The npm tarball layout puts everything under `package/`.
      sourceRoot = "package";
    })
