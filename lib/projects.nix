# Project shell generation: turn a feature's project-directory definitions into
# direnv shells, flat `nix develop` shells, and the home-manager configuration
# that generates the matching `.envrc` files. Used by features that define
# per-directory development environments (personal, work, FOSS contexts).
{lib}: rec {
  # The segments of a project's directory path, which name its shell in the
  # `direnvs` tree: "dev/debian" gives ["dev" "debian"]. A segment may contain
  # a dot, so consumers work from the segment list and never from a dotted
  # string.
  directorySegments = directory:
    lib.filter (segment: segment != "") (lib.splitString "/" directory);

  # Where a project's shell is in the `direnvs` tree, so that "dev" and
  # "dev/debian" can both have one:
  #   ["dev"]           → ["dev" "shell"]
  #   ["dev" "debian"]  → ["dev" "subdirectories" "debian" "shell"]
  treePath = segments:
    [(lib.head segments)]
    ++ lib.concatMap (segment: ["subdirectories" segment]) (lib.tail segments)
    ++ ["shell"];

  # Add the directory's segments to a project definition. Every other field is
  # passed through for the feature's mkShell to use.
  normaliseProject = _name: attrs:
    attrs // {attrSegments = directorySegments attrs.directory;};

  # Build one project's shell with `pkgs.mkShellNoCC`. The optional `base` is
  # merged with the feature's `environment` attributes, and the project's own
  # `extraPackages` are appended to the base package list.
  #
  # Arguments:
  #   pkgs:        the package set for the build system
  #   def:         the project definition, whose optional `extraPackages` is a
  #                function from `pkgs` to a package list
  #   base:        the language shell to build on, `{}` for a feature that
  #                declares no languages
  #   environment: the environment variables the feature sets in every one of
  #                its shells
  mkProjectShell = {
    pkgs,
    def,
    base ? {},
    environment ? {},
  }:
    pkgs.mkShellNoCC (
      base
      // environment
      // {
        packages = (base.packages or []) ++ (def.extraPackages or (_: [])) pkgs;
      }
    );

  # The nested attribute set the `direnvs` output takes. Each node may have
  # a `shell`, the devShell for that directory, and `subdirectories`, the
  # nodes below it.
  mkNestedShells = {
    pkgs,
    platform,
    mkShell,
    projectDefinitions,
  }:
    lib.foldl'
    (
      acc: def:
        lib.recursiveUpdate
        acc
        (lib.setAttrByPath (treePath def.attrSegments) (mkShell pkgs platform def))
    )
    {}
    (builtins.attrValues projectDefinitions);

  # Create flat devShells with "direnvs-" prefix for `nix develop` usage.
  # For example, "dev/debian" becomes devShells.direnvs-dev-debian.
  mkFlatShells = {
    pkgs,
    platform,
    mkShell,
    projectDefinitions,
  }:
    lib.listToAttrs (
      lib.mapAttrsToList (
        _: def: {
          name = "direnvs-" + lib.concatStringsSep "-" def.attrSegments;
          value = mkShell pkgs platform def;
        }
      )
      projectDefinitions
    );

  # Transform projects into the format expected by the project-directories
  # home-manager module (directory path and segments).
  mkDirectoriesConfig = projectDefinitions:
    lib.listToAttrs (
      lib.mapAttrsToList (_: def: {
        name = def.directory;
        value =
          {inherit (def) attrSegments;}
          // lib.optionalAttrs (def ? extraPaths) {inherit (def) extraPaths;};
      })
      projectDefinitions
    );

  mkProjectShells = {
    projects,
    mkShell,
  }: let
    projectDefinitions = lib.mapAttrs normaliseProject projects;
    directories = mkDirectoriesConfig projectDefinitions;
  in {
    homeManagerModule = _: {
      imports = [./project-directories];
      programs.projectDirectories = {
        enable = true;
        inherit directories;
      };
    };
    devShells = {platform}: {pkgs, ...}:
      mkFlatShells {inherit pkgs platform mkShell projectDefinitions;};
    legacyPackages = {platform}: {pkgs, ...}: {
      direnvs = mkNestedShells {inherit pkgs platform mkShell projectDefinitions;};
    };
  };
}
