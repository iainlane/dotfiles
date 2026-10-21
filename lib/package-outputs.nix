# Routes the packages under `pkgs/` into the flake outputs for one platform. A
# package's `passthru.tests` become checks and its `passthru.slowTests` become
# slow checks, each named `<package>-<test>`. Packages and tests that are
# unavailable on the platform are left out.
{lib}: let
  testsFor = attribute: platform: packages: let
    entries = lib.concatLists (lib.mapAttrsToList
      (name: package:
        lib.mapAttrsToList
        (test: lib.nameValuePair "${name}-${test}")
        (lib.filterAttrs (_: lib.meta.availableOn platform) (package.passthru.${attribute} or {})))
      packages);
    names = map (entry: entry.name) entries;
    duplicates = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
  in
    assert lib.assertMsg (duplicates == []) "Package tests have the same output name: ${lib.concatStringsSep ", " duplicates}";
      lib.listToAttrs entries;
in {
  forPlatform = platform: packages: let
    available = lib.filterAttrs (_: lib.meta.availableOn platform) packages;
  in {
    packages = available;
    checks = testsFor "tests" platform available;
    slowChecks = testsFor "slowTests" platform available;
  };
}
