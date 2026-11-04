# Install a Node package's dependencies from its lockfile, with the local npm
# packages in place of their registry releases (see `lib/npm-packages.nix`).
{
  importNpmLock,
  lib,
  localNpmPackages,
}: {
  npmRoot,
  packageLock ? lib.importJSON (npmRoot + "/package-lock.json"),
  package ? lib.importJSON (npmRoot + "/package.json"),
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  local = npmPackages.provide {
    packages = localNpmPackages;
    inherit packageLock;
  };
in {
  npmDeps = importNpmLock {
    inherit npmRoot package;
    inherit (local) packageLock packageSourceOverrides;
  };
  inherit (local) provided;

  # npm reads versions from its hidden lockfile, which copies them from
  # package-lock.json. Without it, `npm ls` compares the installed packages,
  # including the local ones, with what each dependant requires.
  verify = ''
    rm -f node_modules/.package-lock.json
    npm ls --all >/dev/null
  '';
}
