# Project shell generation: turn a profile's project-directory definitions into
# direnv shells, flat `nix develop` shells, and the home-manager configuration
# that generates the matching `.envrc` files. Used by profiles that define
# per-directory development environments (personal, work, FOSS contexts).
{lib}: rec {
  # Normalise project definitions by computing derived path fields.
  # Each project gets:
  #   - attrSegments: directory path split into segments (e.g., "dev/debian" → ["dev" "debian"])
  #   - attrPath: dotted path for nix attribute access (e.g., "dev.debian")
  # All other fields are passed through as-is for the profile's mkShell to use.
  normaliseProject = _name: attrs: let
    attrSegments =
      attrs.attrSegments
      or (lib.filter (segment: segment != "") (lib.splitString "/" attrs.directory));
  in
    attrs
    // {
      inherit attrSegments;
      attrPath = attrs.attrPath or (lib.concatStringsSep "." attrSegments);
    };

  # Derive the kernel/OS name (e.g. "linux", "darwin") from a flake system
  # string so callers can pick `os.<name>` overlays without inspecting `pkgs`
  # at evaluation time.
  osFromSystem = system: (lib.systems.parse.mkSystemFromString system).kernel.name;

  # Create nested attribute structure for the direnvs output. Each node can have:
  #   - shell: the devShell for this directory (optional)
  #   - subdirectories: nested directory nodes (default {})
  # This allows both "dev" and "dev/debian" to have shells without conflicts.
  # For example, "dev" becomes direnvs.dev.shell, "dev/debian" becomes
  # direnvs.dev.subdirectories.debian.shell.
  mkNestedShells = {
    pkgs,
    os,
    mkShell,
    projectDefinitions,
  }: let
    # Build the attribute path for a shell.
    # ["dev"] → ["dev" "shell"]
    # ["dev" "debian"] → ["dev" "subdirectories" "debian" "shell"]
    mkShellPath = segments:
      [(lib.head segments)]
      ++ lib.concatMap (seg: ["subdirectories" seg]) (lib.tail segments)
      ++ ["shell"];
  in
    lib.foldl'
    (
      acc: def:
        lib.recursiveUpdate
        acc
        (lib.setAttrByPath (mkShellPath def.attrSegments) (mkShell pkgs os def))
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
  # home-manager module (directory path and attrPath).
  mkDirectoriesConfig = projectDefinitions:
    lib.listToAttrs (
      lib.mapAttrsToList (_: def: {
        name = def.directory;
        value =
          {inherit (def) attrPath;}
          // lib.optionalAttrs (def ? extraPaths) {inherit (def) extraPaths;};
      })
      projectDefinitions
    );

  # Build direnv shells and devShells for a set of project directories, returning
  # both the flake-parts module and the directories configuration.
  #
  # This is used by profiles that define project-specific development environments.
  # The profile imports the returned module and uses the directories configuration
  # in its homeManagerModule.
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
    # A home-manager module fragment that profiles can import to configure
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
