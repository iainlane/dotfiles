{inputs}: let
  inherit (inputs.nixpkgs) lib;

  # Sorted names for one `builtins.readDir` entry type. Examples of entry types
  # are `"regular"` and `"directory"`. Pass `""` for `suffix` to disable suffix
  # filtering.
  entryNames = dir: entryType: suffix:
    builtins.attrNames (
      lib.filterAttrs (
        name: entryType':
          entryType'
          == entryType
          && lib.hasSuffix suffix name
      )
      (builtins.readDir dir)
    );

  # Sorted regular file names from a directory. Pass `""` for `suffix` to
  # include all regular files.
  fileNames = dir: suffix: entryNames dir "regular" suffix;

  # Sorted directory names from a directory.
  directoryNames = dir: entryNames dir "directory" "";

  # Import all `.nix` files from a directory as a list. Each file may either be
  # a plain value or a function that accepts `args`.
  importNixFiles = dir: args:
    map
    (filename: let
      loaded = import (dir + "/${filename}");
    in
      if builtins.isFunction loaded
      then loaded args
      else loaded)
    (fileNames dir ".nix");

  # Compute the canonical home directory for a user on supported host OSes.
  # Throws if `os` is not one of "darwin" or "linux".
  mkHomeDirectory = {
    os,
    username,
  }: let
    baseDir =
      {
        darwin = "/Users";
        linux = "/home";
      }
      .${
        os
      }
      or (throw "Unsupported OS: ${os}");
  in "${baseDir}/${username}";

  # Hosts from `hosts/*.nix`, keyed by filename (without the `.nix` suffix).
  hosts = lib.listToAttrs (
    map
    (filename: {
      name = lib.removeSuffix ".nix" filename;
      value = import (../hosts + "/${filename}");
    })
    (fileNames ../hosts ".nix")
  );

  # Add a computed `homeDirectory` field to each host config.
  addHostHomeDirectories = {
    hosts,
    username,
  }:
    lib.mapAttrs (
      _: hostConfig:
        hostConfig
        // {
          homeDirectory = mkHomeDirectory {
            inherit (hostConfig) os;
            inherit username;
          };
        }
    )
    hosts;

  # The operating systems in use by our hosts.
  hostOsNames = hosts:
    builtins.attrNames (
      lib.foldl'
      (acc: hostConfig: acc // {"${hostConfig.os}" = true;})
      {}
      (builtins.attrValues hosts)
    );

  # Normalise host profile entries into a flat list of
  # `{ name, profileOptions }`.
  #
  # Supported forms:
  # - "base"
  # - { adsb = { ... }; }                 # single-key attrset
  # - { base = {}; adsb = { ... }; }      # multi-key attrset
  #
  # Duplicate profile names are rejected to avoid ambiguous merge behaviour.
  normaliseProfileEntries = profileEntries: let
    addEntry = state: name: profileOptions:
      if builtins.hasAttr name state.seen
      then throw "Profile '${name}' is declared multiple times in host profiles"
      else {
        seen = state.seen // {"${name}" = true;};
        entries = [{inherit name profileOptions;}] ++ state.entries;
      };

    parseAndAdd = state: entry:
      if builtins.isString entry
      then addEntry state entry null
      else if builtins.isAttrs entry
      then
        lib.foldl' (
          innerState: name: let
            raw = entry.${name};
          in
            addEntry
            innerState
            name
            (
              if raw == null
              then {}
              else raw
            )
        )
        state
        (builtins.attrNames entry)
      else throw "Profile entry must be a string or an attrset";

    deduped =
      lib.foldl' parseAndAdd {
        seen = {};
        entries = [];
      }
      profileEntries;
  in
    lib.reverseList deduped.entries;

  # Build the list of modules for one module type ("homeManagerModule" or
  # "systemManagerModule").
  #
  # For each host profile entry:
  # - read the base profile module,
  # - read an optional OS-specific profile module (e.g. `linux.nix`),
  # - apply profile options when the profile is declared as
  #   `{ name = { ... }; }`.
  #
  # Errors:
  # - profile name not found -> error
  # - profile declared twice -> handled earlier by `normaliseProfileEntries`
  # - options passed to a profile that does not take options -> error
  # - options missing for a profile that requires options -> error
  mkModules = {
    moduleType,
    hostConfig,
    profiles,
  }: let
    inherit (hostConfig) os;
    entries = normaliseProfileEntries hostConfig.profiles;

    # Some profile entries are functions that must be called with profile
    # options. This returns true for that function shape.
    moduleNeedsProfileOptions = moduleValue:
      builtins.isFunction moduleValue
      && builtins.functionArgs moduleValue == {};

    # Apply one module value for one profile entry.
    # Returns [] when moduleValue is null, otherwise returns a one-element list.
    applyProfileModule = entry: moduleValue:
      if moduleValue == null
      then []
      else let
        needsProfileOptions = moduleNeedsProfileOptions moduleValue;
        hasOptions = entry.profileOptions != null;
        emptyOptions = entry.profileOptions == {};
      in
        if needsProfileOptions
        then
          if !hasOptions
          then throw "Profile '${entry.name}' requires profile options, e.g. { ${entry.name} = { ... }; }"
          else [(moduleValue entry.profileOptions)]
        else if !hasOptions || emptyOptions
        then [moduleValue]
        else throw "Profile '${entry.name}' does not accept profile options; use a string entry.";

    # Resolve and apply both base and OS-specific module values for one entry.
    resolveEntry = entry: let
      profile = profiles.${entry.name} or (throw "Profile '${entry.name}' not found in flake.profiles");
      baseVal = profile.${moduleType};
      osVal = (profile.os.${os} or {}).${moduleType} or null;
    in
      lib.concatMap (applyProfileModule entry) [
        baseVal
        osVal
      ];
  in
    lib.concatMap resolveEntry entries;

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
    homeDir = mkHomeDirectory {
      inherit (hostConfig) os;
      inherit username;
    };
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

  # Assemble home-manager modules and special args for a host in one place so
  # standalone home-manager and nix-darwin embedding stay in sync.
  mkHomeConfiguration = {
    hostConfig,
    hostname,
    system,
    username,
    profiles,
    extraModules ? [],
    extraSpecialArgs ? {},
  }: {
    modules =
      mkHomeModules {
        inherit
          hostConfig
          username
          profiles
          ;
      }
      ++ [inputs.sops-nix.homeManagerModules.sops]
      ++ extraModules;
    extraSpecialArgs = mkHomeSpecialArgs {
      inherit
        hostConfig
        hostname
        system
        username
        ;
      inputs = inputs;
      extraArgs = extraSpecialArgs;
    };
  };

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
    (
      acc: def:
        lib.recursiveUpdate
        acc
        (lib.setAttrByPath (mkShellPath def.attrSegments) (mkShell pkgs def))
    )
    {}
    (builtins.attrValues projectDefinitions);

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
            {config, ...}: let
              projectPkgs = config._module.args.pkgs;
            in
              mkNestedShells {
                pkgs = projectPkgs;
                inherit mkShell projectDefinitions;
              }
          )
      );

      # Export flat devShells for manual `nix develop` usage. Useful for testing
      # or entering a project environment without direnv.
      perSystem = {config, ...}: let
        projectPkgs = config._module.args.pkgs;
      in {
        devShells = mkFlatShells {
          pkgs = projectPkgs;
          inherit mkShell projectDefinitions;
        };
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
    addHostHomeDirectories
    directoryNames
    fileNames
    hostOsNames
    hosts
    importNixFiles
    mkHomeConfiguration
    mkProjectShells
    mkSystemModules
    ;
}
