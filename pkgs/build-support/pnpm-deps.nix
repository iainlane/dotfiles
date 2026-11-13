# Fetch a pnpm project's dependencies, with the local npm packages in place of
# their registry releases (see `lib/npm-packages.nix`).
#
# The project's pnpm overrides point each local package at
# `.nix-providers/<tarball>`, and the lockfile records the tarball's integrity.
# The build, the development shell and the updater link the tarballs there
# before running pnpm.
{
  fetchPnpmDeps,
  lib,
  localNpmPackages,
}: {
  npmRoot,
  pname,
  src,
  sourceRoot,
  pnpm,
  hash,
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  lockfile = builtins.readFile (npmRoot + "/pnpm-lock.yaml");
  overrides = npmPackages.pnpmOverrides {
    packages = localNpmPackages;
    inherit lockfile;
  };
  providers = import ./pnpm-providers.nix {inherit lib;} overrides;
  linkProviders = providers.link;

  prePnpmInstall = ''
    ${providers.check "pnpm-lock.yaml"}
    ${linkProviders "."}
  '';

  pnpmDeps = fetchPnpmDeps {
    inherit pname src sourceRoot pnpm hash prePnpmInstall;
    fetcherVersion = 5;
  };
in {
  inherit pnpmDeps overrides linkProviders prePnpmInstall;
}
