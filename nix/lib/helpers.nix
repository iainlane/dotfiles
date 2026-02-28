{inputs}: let
  inherit (inputs.nixpkgs) lib;

  # Extract name and args from a profile list entry.
  # String entries ("base") → { name, args = null }
  # Attrset entries ({ adsb = {}; }) → { name, args }
  parseProfileEntry = entry:
    if builtins.isString entry
    then {
      name = entry;
      args = null;
    }
    else let
      names = builtins.attrNames entry;
    in {
      name = builtins.head names;
      args = entry.${builtins.head names};
    };

  # Unified module resolver parameterised by module type. For each profile
  # entry, looks up the base and OS-specific module values. If the entry was
  # an attrset (args != null), calls the module value as a function with args.
  mkModules = {
    moduleType,
    hostConfig,
    profiles,
  }: let
    inherit (hostConfig) os;

    resolveEntry = entry: let
      parsed = parseProfileEntry entry;
      profile = profiles.${parsed.name} or (throw "Profile '${parsed.name}' not found in flake.profiles");
      baseVal = profile.${moduleType};
      osVal = (profile.os.${os} or {}).${moduleType} or null;
      resolve = val:
        if val == null
        then []
        else if parsed.args != null
        then [(val parsed.args)]
        else [val];
    in
      resolve baseVal ++ resolve osVal;
  in
    lib.concatMap resolveEntry hostConfig.profiles;

  mkHomeModules = {
    hostConfig,
    username,
    profiles,
  }:
    mkModules {
      moduleType = "homeManagerModule";
      inherit hostConfig profiles;
    }
    ++ lib.optional (hostConfig ? homeModule) hostConfig.homeModule
    ++ [
      {
        home = {
          inherit username;
          inherit (hostConfig) homeDirectory;
        };
      }
    ];

  mkSystemModules = {
    hostConfig,
    profiles,
  }:
    mkModules {
      moduleType = "systemManagerModule";
      inherit hostConfig profiles;
    }
    ++ lib.optional (hostConfig ? systemModule) hostConfig.systemModule;

  # Construct the specialArgs attrset passed to home-manager modules. Provides
  # access to flake inputs, host metadata, and path helpers. This allows modules
  # to reference inputs, check the current hostname/system, and locate other
  # modules or profiles.
  mkHomeSpecialArgs = {
    hostConfig,
    hostname,
    system,
    inputs,
    username,
    extraArgs ? {},
  }: let
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

  # Create nested attribute structure for the direnvs output. Each node can have:
  #   - shell: the devShell for this directory (optional)
  #   - subdirectories: nested directory nodes (default {})
  # This allows both "dev" and "dev/debian" to have shells without conflicts.
  # For example, "dev" becomes direnvs.dev.shell, "dev/debian" becomes
  # direnvs.dev.subdirectories.debian.shell.
  mkNestedShells = {
    pkgs,
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
    lib.recursiveUpdate
    {}
    (lib.mapAttrsToList (
        _: def: lib.setAttrByPath (mkShellPath def.attrSegments) (mkShell pkgs def)
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
  # home-manager module (directory path and attrPath).
  mkDirectoriesConfig = projectDefinitions:
    lib.listToAttrs (
      lib.mapAttrsToList (_: def: {
        name = def.directory;
        value = {inherit (def) attrPath;};
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
  #   mkShell:     Function (pkgs -> projectDef -> derivation) that builds a shell
  #                for a project. This is where you set environment variables and
  #                add packages specific to your projects.
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
    mkSystemModules
    ;
}
