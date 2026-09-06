# Checks where the definitions of `flake.features` come from.
#
# `docs/architecture.md` gives two rules for the layout of `features/`: a
# top-level feature is registered by the `default.nix` of its own directory,
# and every other concern is a child of that feature, registered under its
# `provides`.
#
# The module system records the file each definition came from, so both rules
# are decided from the definitions of `options.flake`. flake-parts declares
# `flake` as a single submodule option, so every module's `flake = {...}` is
# one definition against it and the registry is that definition's `features`
# attribute.
#
# One directory may register several features when the names extend the
# directory's own. `features/nixbuild/default.nix` registers
# `nixbuild-substituter` and `nixbuild-builder`, and
# `features/agentsview/default.nix` registers `agentsview` and
# `agentsview-server`; each pair shares constants that only make sense
# together.
{
  lib,
  options,
  ...
}: let
  # The segments of a definition's file path from the `features` directory
  # down, or null for a definition written anywhere else. The checkout may
  # itself sit under a directory called `features`, so the last such segment
  # is where the feature path starts.
  featurePath = file: let
    segments = lib.splitString "/" file;

    positions =
      lib.filter
      (index: lib.elemAt segments index == "features")
      (lib.range 0 (lib.length segments - 1));
  in
    if positions == []
    then null
    else lib.drop (lib.last positions + 1) segments;

  # Whether a feature of this name belongs to this directory. `git` belongs to
  # `features/git`, and `nixbuild-builder` to `features/nixbuild`.
  directoryOwns = directory: name: directory == name || lib.hasPrefix "${directory}-" name;

  # One record per feature each definition mentions: what the definition sets,
  # and where it was written.
  mentions =
    lib.concatMap (
      definition: let
        path = featurePath definition.file;
      in
        lib.mapAttrsToList (name: value: {
          inherit name path;
          inherit (definition) file;

          # A definition that sets nothing but `provides` adds children to a
          # feature. Anything else registers the feature itself.
          providesOnly = lib.isAttrs value && lib.attrNames value == ["provides"];
        })
        (definition.value.features or {})
    )
    options.flake.definitionsWithLocations;

  belongsHere = mention: mention.path != null && directoryOwns (lib.head mention.path) mention.name;

  isEntryPoint = mention: mention.path == [(lib.head mention.path) "default.nix"];

  badRegistrations =
    lib.filter
    (mention: !mention.providesOnly && !(belongsHere mention && isEntryPoint mention))
    mentions;

  badContributions =
    lib.filter
    (mention: mention.providesOnly && !(belongsHere mention))
    mentions;

  # A definition inside `features/` is named by its path from there, which is
  # the file a reader has to go and edit.
  location = mention:
    if mention.path == null
    then mention.file
    else "features/${lib.concatStringsSep "/" mention.path}";

  describe = verb: mention: "  ✗ ${location mention} ${verb} ${mention.name}";

  report = lib.concatStringsSep "\n" (
    map (describe "registers the top-level feature") badRegistrations
    ++ map (describe "adds children to") badContributions
  );
in {
  perSystem = {pkgs, ...}: {
    checks.feature-registration =
      pkgs.runCommandLocal "feature-registration" {inherit report;}
      (
        if report == ""
        then "touch $out"
        else ''
          echo "features are registered outside the directory they belong to:" >&2
          printf '%s\n' "$report" >&2
          echo >&2
          echo "A top-level feature is registered by features/<name>/default.nix." >&2
          echo "Everything else in that directory is a child under its provides." >&2
          exit 1
        ''
      );
  };
}
