# npm tarballs omit package-lock.json, so the updater resolves their manifests.
# GitHub sources use the release's lockfile. Both are committed in npm-deps/;
# the build must not resolve dependencies again.
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
  # JSON with a version and either a GitHub source hash or a tarball hash.
  source,
  # The directory containing the lockfile.
  npmRoot,
  # {owner, repo} for a release tag, or null for a registry tarball.
  gitHub ? null,
  tagPrefix ? "v",
  description,
  # Dependency overrides for registry tarballs. The updater applies these
  # before resolving the lockfile; GitHub sources use the upstream lockfile.
  npmDependencies ? {},
  # npm distributes platform-specific native addons as optional dependencies.
  # Set this to false for extensions that require a native addon.
  omitOptional ? true,
}: let
  pin = lib.importJSON source;

  # `overlays/local-pkgs.nix` derives each package's attribute from its
  # directory, so a scoped extension is packaged under its basename alone.
  pname = lib.last (lib.splitString "/" npmName);

  packageLock = lib.importJSON (npmRoot + "/package-lock.json");

  # The updater keeps only the lockfile. Its root record contains the manifest.
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

      # The source manifest must match the overrides in the committed lockfile.
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

      npmInstallFlags =
        ["--omit=dev"]
        ++ lib.optional omitOptional "--omit=optional";

      dontNpmBuild = true;

      # npm prune tries to fetch dev dependencies even though the install
      # omitted them. The sandbox cannot fetch those dependencies.
      dontNpmPrune = true;

      # npmInstallHook uses npm pack --dry-run, which still runs prepack.
      # The extension is prebuilt and its build tools are not installed.
      npmPackFlags = ["--ignore-scripts"];

      # With no runtime dependencies, npm creates no node_modules directory.
      # npmInstallHook would try to copy that missing directory unless the
      # destination already exists.
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
      sourceRoot = "package";
    })
