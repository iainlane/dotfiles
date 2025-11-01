# Helper functions used throughout the flake.
#
# These functions abstract common patterns for building home-manager configs,
# creating development shells, and transforming data structures. If you're new
# to Nix, here's a quick orientation:
#
# - Functions in Nix are defined with `name = args: body;` syntax
# - `{ foo, bar, ... }:` destructures an attrset argument
# - `let ... in` introduces local bindings
# - `lib` comes from nixpkgs and provides utility functions (map, filter, etc.)
# - Attrsets (like `{ a = 1; b = 2; }`) are Nix's dictionary/object type
#
# Most of these helpers transform host configuration into the structures that
# home-manager and flake-parts expect.
{inputs}: let
  inherit (inputs.nixpkgs) lib;

  # Construct the list of modules for a home-manager configuration.
  #
  # In Nix, a "module" is a file that contributes configuration. home-manager
  # merges all modules together to produce the final config. This function
  # collects:
  # - Profile modules (base, desktop, etc.) based on what the host specifies
  # - An optional host-specific module for per-machine overrides
  # - Basic home settings (username, home directory)
  #
  # The result is a list that gets passed to home-manager's `modules` option.
  mkHomeModules = {
    hostConfig,
    username,
    homeManagerModules,
  }: let
    inherit (hostConfig) homeDirectory;

    resolvedModules =
      map (
        profileName:
          homeManagerModules.${profileName} or (throw "Profile '${profileName}' not found in homeManagerModules")
      )
      hostConfig.profiles;
  in
    resolvedModules
    ++ lib.optional (hostConfig ? homeModule) hostConfig.homeModule
    ++ [
      {
        home = {
          inherit username;
          inherit homeDirectory;
        };
      }
    ];

  # Construct "specialArgs" - extra arguments available to all home-manager modules.
  #
  # Normally, home-manager modules only receive standard arguments like `config`,
  # `pkgs`, and `lib`. specialArgs lets us pass additional values that modules
  # can destructure, such as:
  # - `inputs`: access to flake inputs (for overlays, other flakes)
  # - `hostname`: the current machine's name
  # - `hostConfig`: the full host configuration from hosts/*.nix
  # - `mkProfileImports`: helper for loading OS-specific module variants
  #
  # Example usage in a module: `{ pkgs, inputs, hostname, ... }: { ... }`
  mkHomeSpecialArgs = {
    hostConfig,
    hostname,
    system,
    inputs,
    username,
    extraArgs ? {},
  }: let
    profileLib = import ../lib/mkProfile.nix {inherit lib;};
    homeDir =
      if hostConfig.os == "darwin"
      then "/Users/${username}"
      else "/home/${username}";
    defaultFlakePath = "${homeDir}/dev/random/dotfiles/nix";
    flakePath = hostConfig.flakePath or defaultFlakePath;
  in
    {
      inherit
        hostname
        inputs
        system
        hostConfig
        flakePath
        ;
      # Partially apply mkProfileImports with hostConfig so modules can use it
      # without having to pass hostConfig explicitly each time.
      mkProfileImports = profileLib.mkProfileImports hostConfig;
      modulesPath = ../modules;
      profilesPath = ../profiles;
    }
    // extraArgs;

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

  # Create nested attribute structure for the direnvs output, organised by
  # directory path segments. For example, "dev/debian" becomes direnvs.dev.debian.
  # This matches the flake reference format used in .envrc files.
  mkNestedShells = {
    pkgs,
    mkShell,
    projectDefinitions,
  }:
    lib.foldl'
    lib.recursiveUpdate
    {}
    (lib.mapAttrsToList (
        _: def: lib.setAttrByPath def.attrSegments (mkShell pkgs def)
      )
      projectDefinitions);

  # Create flat devShells with "direnvs-" prefix for `nix develop` usage.
  # For example, "dev/debian" becomes devShells.direnvs-dev-debian.
  mkFlatShells = {
    pkgs,
    mkShell,
    projectDefinitions,
  }:
    lib.listToAttrs (
      lib.mapAttrsToList (
        _: def: {
          name = "direnvs-" + lib.concatStringsSep "-" def.attrSegments;
          value = mkShell pkgs def;
        }
      )
      projectDefinitions
    );

  # Transform projects into the format expected by the project-directories
  # home-manager module (just directory path and attrPath).
  mkDirectoriesConfig = projectDefinitions:
    lib.listToAttrs (
      lib.mapAttrsToList (_: def: {
        name = def.directory;
        value = {
          inherit (def) attrPath;
        };
      })
      projectDefinitions
    );

  # Build direnv shells for project directories.
  #
  # This is the core of the per-directory environment system. It takes a set of
  # project definitions (each with a directory path and custom settings) and
  # produces:
  # 1. Nix shells with the right environment variables (git identity, etc.)
  # 2. Configuration for home-manager to generate .envrc files
  #
  # When you `cd` into a project directory, direnv sees the .envrc and loads the
  # corresponding Nix shell. This switches your git identity, adds project-specific
  # tools, and sets any other environment variables you've defined.
  #
  # How the pieces fit together:
  # - `projects`: Your project definitions (directory, email, packages, etc.)
  # - `mkShell`: A function you provide that turns a project definition into a
  #   Nix shell derivation. This is where you decide what env vars to set.
  # - The returned `flakeModule` exports the shells so direnv can reference them
  # - The returned `homeManagerModule` tells home-manager to create .envrc files
  #
  # See profiles/home/default.nix for a complete example.
  #
  # Arguments:
  #   config:      The flake-parts config (provides config.systems)
  #   withSystem:  flake-parts' withSystem for per-architecture evaluation
  #   projects:    Attrset of project definitions (must include `directory`)
  #   mkShell:     Function (pkgs -> projectDef -> derivation) that creates shells
  #
  # Returns:
  #   - homeManagerModule: Configures the project-directories home-manager module
  #   - flakeModule: Exports shells as flake outputs (direnvs.* and devShells.*)
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
    # project-directories.
    homeManagerModule = {modulesPath, ...}: {
      imports = [(modulesPath + /project-directories)];

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
              mkNestedShells {inherit pkgs mkShell projectDefinitions;}
          )
      );

      # Export flat devShells for manual `nix develop` usage. Useful for testing
      # or entering a project environment without direnv.
      perSystem = {pkgs, ...}: {
        devShells = mkFlatShells {inherit pkgs mkShell projectDefinitions;};
      };
    };
  };
in {
  # Map host metadata onto canonical Nix system strings ("x86_64-linux",
  # "aarch64-darwin", etc). This lets host definitions use simple "os" and
  # "arch" fields instead of repeating the full system string.
  mkSystem = config:
    assert lib.assertMsg (builtins.elem config.os ["darwin" "linux"])
    "mkSystem: config.os must be 'darwin' or 'linux', got '${config.os}'";
    assert lib.assertMsg (builtins.elem config.arch ["x86_64" "aarch64"])
    "mkSystem: config.arch must be 'x86_64' or 'aarch64', got '${config.arch}'"; "${config.arch}-${
      if config.os == "darwin"
      then "darwin"
      else "linux"
    }";

  inherit
    mkHomeModules
    mkHomeSpecialArgs
    mkProjectShells
    ;
}
