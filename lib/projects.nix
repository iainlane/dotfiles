# Project shell generation: turn a feature's project-directory definitions into
# direnv shells, flat `nix develop` shells, and the home-manager configuration
# that generates the matching `.envrc` files. Used by features that define
# per-directory development environments (personal, work, FOSS contexts).
{lib}: rec {
  # The segments of a project's directory path, which name its shell in the
  # `direnvs` tree: "dev/debian" gives ["dev" "debian"]. A segment may contain
  # a dot, so the segments are what every consumer works from.
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

  # Derive the kernel/OS name (e.g. "linux", "darwin") from a flake system
  # string so callers can pick `os.<name>` overlays without inspecting `pkgs`
  # at evaluation time.
  osFromSystem = system: (lib.systems.parse.mkSystemFromString system).kernel.name;

  # Create nested attribute structure for the direnvs output. Each node can have:
  #   - shell: the devShell for this directory (optional)
  #   - subdirectories: nested directory nodes (default {})
  mkNestedShells = {
    pkgs,
    os,
    mkShell,
    projectDefinitions,
  }:
    lib.foldl'
    (
      acc: def:
        lib.recursiveUpdate
        acc
        (lib.setAttrByPath (treePath def.attrSegments) (mkShell pkgs os def))
    )
    {}
    (builtins.attrValues projectDefinitions);

  # Create flat devShells with "direnvs-" prefix for `nix develop` usage.
  # For example, "dev/debian" becomes devShells.direnvs-dev-debian.
  mkFlatShells = {
    pkgs,
    os,
    mkShell,
    projectDefinitions,
  }:
    lib.listToAttrs (
      lib.mapAttrsToList (
        _: def: {
          name = "direnvs-" + lib.concatStringsSep "-" def.attrSegments;
          value = mkShell pkgs os def;
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

  # Build direnv shells and devShells for a set of project directories, returning
  # both the flake-parts module and the directories configuration.
  #
  # This is used by features that define project-specific development environments.
  # The feature imports the returned module and uses the directories configuration
  # in its `homeManager` module.
  #
  # The direnv system automatically generates .envrc files that set up per-directory
  # development environments with custom environment variables (email, git config, etc).
  # This is particularly useful for managing multiple work contexts (personal, work, FOSS)
  # with different identities and tooling.
  #
  # Arguments:
  #   config:      The flake-parts config, needed for config.systems
  #   withSystem:  flake-parts' withSystem function for per-system evaluation
  #   projects:    Attrset of project directories with their configurations
  #                Each project should define at minimum: directory
  #   mkShell:     Function (pkgs -> os -> projectDef -> derivation) that builds
  #                a shell for a project. `os` is the kernel name (e.g. "linux",
  #                "darwin") derived from the build system, so callers can pick
  #                the matching `os.<name>` overlay without runtime conditionals.
  #                This is where you set environment variables and add packages
  #                specific to your projects.
  #
  # Returns: An attrset with:
  #   - homeManagerModule: A home-manager module fragment for project-directories config
  #   - flakeModule: A flake-parts module that contributes direnvs and devShells
  mkProjectShells = {
    config,
    withSystem,
    projects,
    mkShell,
  }: let
    projectDefinitions = lib.mapAttrs normaliseProject projects;
    directories = mkDirectoriesConfig projectDefinitions;
  in {
    # A home-manager module fragment that features can import to configure
    # project-directories. This reduces boilerplate.
    homeManagerModule = _: {
      imports = [./project-directories];

      programs.projectDirectories = {
        enable = true;
        inherit directories;
      };
    };

    # A flake-parts module that contributes direnvs and devShells
    flakeModule = {
      # Export nested direnv shells organised by directory path, used by the
      # home-manager module to generate .envrc files referencing these shells.
      flake.direnvs = lib.genAttrs config.systems (
        system:
          withSystem system (
            {config, ...}: let
              projectPkgs = config._module.args.pkgs;
            in
              mkNestedShells {
                pkgs = projectPkgs;
                os = osFromSystem system;
                inherit mkShell projectDefinitions;
              }
          )
      );

      # Export flat devShells for manual `nix develop` usage. Useful for testing
      # or entering a project environment without direnv.
      perSystem = {
        config,
        system,
        ...
      }: let
        projectPkgs = config._module.args.pkgs;
      in {
        devShells = mkFlatShells {
          pkgs = projectPkgs;
          os = osFromSystem system;
          inherit mkShell projectDefinitions;
        };
      };
    };
  };
}
