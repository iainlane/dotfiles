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

  # The kernel name ("linux", "darwin") of a flake system string, so a caller
  # can select a `kernel.<name>` overlay without inspecting `pkgs` at
  # evaluation time.
  kernelFromSystem = system: (lib.systems.parse.mkSystemFromString system).kernel.name;

  # The nested attribute set the `direnvs` output takes. Each node may have
  # a `shell`, the devShell for that directory, and `subdirectories`, the
  # nodes below it.
  mkNestedShells = {
    pkgs,
    kernel,
    mkShell,
    projectDefinitions,
  }:
    lib.foldl'
    (
      acc: def:
        lib.recursiveUpdate
        acc
        (lib.setAttrByPath (treePath def.attrSegments) (mkShell pkgs kernel def))
    )
    {}
    (builtins.attrValues projectDefinitions);

  # Create flat devShells with "direnvs-" prefix for `nix develop` usage.
  # For example, "dev/debian" becomes devShells.direnvs-dev-debian.
  mkFlatShells = {
    pkgs,
    kernel,
    mkShell,
    projectDefinitions,
  }:
    lib.listToAttrs (
      lib.mapAttrsToList (
        _: def: {
          name = "direnvs-" + lib.concatStringsSep "-" def.attrSegments;
          value = mkShell pkgs kernel def;
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

  # Build the direnv shells and devShells for a set of project directories.
  # A feature imports the returned flake-parts module and puts the returned
  # Home Manager module in its `homeManager` field. That module writes an
  # `.envrc` in each project directory to load that directory's shell, so one
  # machine gets a different identity and toolchain in each of them.
  #
  # Arguments:
  #   config:      the flake-parts config, for `config.systems`
  #   withSystem:  flake-parts' per-system evaluation function
  #   projects:    the project directories, each defining at least `directory`
  #   mkShell:     `pkgs -> kernel -> projectDef -> derivation`, building one
  #                project's shell. `kernel` is "linux" or "darwin", taken
  #                from the build system, so the shell can select the matching
  #                `kernel.<name>` overlay without a runtime test. This is
  #                where the environment variables and extra packages go.
  #
  # Returns:
  #   homeManagerModule: the Home Manager module configuring
  #                      `programs.projectDirectories`
  #   flakeModule:       the flake-parts module contributing `direnvs` and
  #                      `devShells`
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
    # project-directories.
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
            {pkgs, ...}:
              mkNestedShells {
                inherit pkgs mkShell projectDefinitions;
                kernel = kernelFromSystem system;
              }
          )
      );

      # Export flat devShells for manual `nix develop` usage. Useful for testing
      # or entering a project environment without direnv.
      perSystem = {
        pkgs,
        system,
        ...
      }: {
        devShells = mkFlatShells {
          inherit pkgs mkShell projectDefinitions;
          kernel = kernelFromSystem system;
        };
      };
    };
  };
}
