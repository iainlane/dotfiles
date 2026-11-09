# Fetch a pnpm package's dependencies from its committed lockfile, and install
# the local npm packages in place of their registry releases (see
# `lib/npm-packages.nix`). The fetched store depends only on the lockfile, so
# changing a local package does not change the dependency hash.
{
  fetchPnpmDeps,
  lib,
  localNpmPackages,
  writeText,
}: {
  pnpmRoot,
  pname,
  src,
  sourceRoot,
  pnpm,
  hash,
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  # The keys are npm names. nixpkgs-stable drops `meta.identifiers`, so the
  # packages cannot report their own npm names on every channel.
  providing = npmPackages.providePnpm {
    packages = localNpmPackages;
    lockfile = builtins.readFile (pnpmRoot + "/pnpm-lock.yaml");
  };
  provided = lib.attrValues providing;
  providers = writeText "${pname}-npm-packages.json" (builtins.toJSON (lib.mapAttrsToList (name: package: {
      inherit name;
      tarball = toString package.npmTarball;
    })
    providing));
in {
  pnpmDeps = fetchPnpmDeps {
    inherit pname src sourceRoot pnpm hash;
    fetcherVersion = 5;
  };
  inherit provided;

  # Run after each `pnpm install`.
  substitute = ''
    bash ${./pnpm-local-packages.bash} ${providers}
  '';
}
