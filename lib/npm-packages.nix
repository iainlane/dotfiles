# A local package that builds an npm package records the npm name and version
# in `meta.identifiers.purlParts`, nixpkgs' field for Package URLs, and exposes
# the package as `passthru.npmTarball`. Builds that use
# `pkgs/build-support/npm-deps.nix` or `pkgs/build-support/pnpm-deps.nix`
# install that tarball for every lockfile entry with the same name, in place of
# the registry release.
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
  in {
    packageLock =
      packageLock
      // {
        packages = packageLock.packages // lib.mapAttrs (_: entry: removeAttrs entry ["integrity"]) matches;
      };
    packageSourceOverrides = lib.mapAttrs (path: _: packages.${packageName path}.npmTarball) matches;
  };

  # The file name that `npm pack` gives a package's tarball.
  tarballName = {
    name,
    version,
  }: "${lib.replaceStrings ["@" "/"] ["" "-"] name}-${version}.tgz";

  # A local package as a pnpm override target: its npm name and version, the
  # tarball's name in `.nix-providers` and the tarball itself.
  pnpmProvider = package: let
    npm = npmPackage package;
  in
    npm
    // {
      file = tarballName npm;
      inherit (package) npmTarball;
    };

  # Nix has no built-in YAML parser. Match pnpm's package-key prefixes
  # here so evaluation does not need IFD.
  providePnpm = {
    packages,
    lockfile,
  }: let
    lines = lib.splitString "\n" lockfile;
    matches = name: lib.any (line: lib.any (quote: lib.hasPrefix "  ${quote}${name}@" line) ["" "'" "\""]) lines;
  in
    lib.attrValues (lib.filterAttrs (name: _: matches name) packages);

  # The pnpm overrides that install the local packages in a lockfile. An
  # override of a package's name does not reach an npm alias of it, such as
  # `"old-name": "npm:new-name@1.0.0"`, so each alias gets its own override.
  # A snapshot records an alias as `old-name: 'new-name@...'`. An importer
  # records it as an `old-name:` key whose `version` two lines later starts
  # with `new-name@`.
  pnpmOverrides = {
    packages,
    lockfile,
  }: let
    lines = lib.splitString "\n" lockfile;
    aliases = name: let
      package = "['\"]?${lib.escapeRegex name}@.*";
      alias = index: line: let
        snapshot = builtins.match "      ['\"]?([^'\": ]+)['\"]?: ${package}" line;
        importer = builtins.match "      ['\"]?([^'\": ]+)['\"]?:" (builtins.elemAt lines (index - 2));
      in
        if snapshot != null
        then snapshot
        else if index >= 2 && builtins.match "        version: ${package}" line != null
        then importer
        else null;
    in
      lib.filter (alias: alias != name) (lib.unique (lib.concatMap (match: lib.optional (match != null) (builtins.head match)) (lib.imap0 alias lines)));
  in
    lib.concatMap (package: let
      provider = pnpmProvider package;
    in
      [provider] ++ map (alias: provider // {name = alias;}) (aliases provider.name))
    (providePnpm {inherit packages lockfile;});
}
