# A local package that builds an npm package records the npm name and version
# in `meta.identifiers.purlParts`, nixpkgs' field for Package URLs, and exposes
# the package as `passthru.npmTarball`. A build that uses
# `pkgs/build-support/npm-deps.nix` installs that tarball for every lockfile
# entry with the same name, in place of the registry release.
{lib}: rec {
  # The purl spec percent-encodes the `@` of an npm scope.
  purlParts = {
    name,
    version,
  }: {
    type = "npm";
    spec = "${lib.replaceStrings ["@"] ["%40"] name}@${version}";
  };

  # The npm name and version of a package, or null when it has no npm purl.
  npmPackage = package: let
    parts = package.meta.identifiers.purlParts or {};
    spec = builtins.match "(.+)@([^@]+)" (lib.replaceStrings ["%40"] ["@"] parts.spec);
  in
    if parts.type or null == "npm"
    then {
      name = builtins.elemAt spec 0;
      version = builtins.elemAt spec 1;
    }
    else null;

  # The attribute names of the packages with an npm purl, keyed by npm name.
  attributesByName = packages:
    lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (
        attribute: package: let
          npm = npmPackage package;
        in
          lib.optional (npm != null) (lib.nameValuePair npm.name attribute)
      )
      packages));

  # The packages with an npm purl, keyed by npm name.
  byName = packages: lib.mapAttrs (_: attribute: packages.${attribute}) (attributesByName packages);

  # The `importNpmLock` arguments that install `packages` in place of their
  # registry releases. An alias entry records the package that it installs as
  # its `name`. npm checks a tarball against the lockfile's `integrity`, which
  # belongs to the registry release, so the matching entries lose it.
  # `provided` lists the packages that the lockfile uses.
  provide = {
    packages,
    packageLock,
  }: let
    packageName = path: packageLock.packages.${path}.name or (lib.last (lib.splitString "node_modules/" path));
    matches =
      lib.filterAttrs (
        path: entry: path != "" && !(entry.link or false) && packages ? ${packageName path}
      )
      packageLock.packages;
    providing = path: packages.${packageName path};
  in {
    packageLock =
      packageLock
      // {
        packages = packageLock.packages // lib.mapAttrs (_: entry: removeAttrs entry ["integrity"]) matches;
      };
    packageSourceOverrides = lib.mapAttrs (path: _: (providing path).npmTarball) matches;
    provided = lib.unique (map providing (lib.attrNames matches));
  };

  # The packages, keyed by npm name, that a pnpm lockfile uses. Nix has no
  # built-in YAML parser. Match pnpm's package-key prefixes here so evaluation
  # does not need IFD.
  providePnpm = {
    packages,
    lockfile,
  }: let
    lines = lib.splitString "\n" lockfile;
    matches = name: lib.any (line: lib.any (quote: lib.hasPrefix "  ${quote}${name}@" line) ["" "'" "\""]) lines;
  in
    lib.filterAttrs (name: _: matches name) packages;
}
