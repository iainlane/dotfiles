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

  # Discover flake-parts modules: list subdirectories of `dir` that contain a
  # `default.nix` and return paths to those files.
  discoverModules = dir:
    map
    (name: dir + "/${name}/default.nix")
    (builtins.filter
      (name: builtins.pathExists (dir + "/${name}/default.nix"))
      (directoryNames dir));

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

  # Collect module lists exported by selected feature modules.
  # `moduleType` should be one of `homeManagerModules` or `systemManagerModules`.
  collectFeatureModules = {
    modules,
    moduleType,
    os ? null,
  }:
    builtins.concatLists (
      map
      (module:
        if os == null
        then module.${moduleType}
        else lib.attrByPath ["os" os moduleType] [] module)
      modules
    );

  # Hosts from `hosts/*.nix` and `hosts/*/default.nix`, keyed by name.
  hosts = let
    # File-based hosts: hosts/foo.nix -> { name = "foo"; value = ...; }
    fileHosts =
      map
      (filename: {
        name = lib.removeSuffix ".nix" filename;
        value = import (../hosts + "/${filename}");
      })
      (fileNames ../hosts ".nix");

    # Directory-based hosts: hosts/foo/default.nix -> { name = "foo"; ... }
    dirHosts =
      map
      (dirname: {
        name = dirname;
        value = import (../hosts + "/${dirname}/default.nix");
      })
      (builtins.filter
        (dirname:
          builtins.pathExists (../hosts + "/${dirname}/default.nix"))
        (directoryNames ../hosts));
  in
    lib.listToAttrs (fileHosts ++ dirHosts);

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
    featureModuleType =
      if moduleType == "homeManagerModule"
      then "homeManagerModules"
      else if moduleType == "nixosModule"
      then "nixosModules"
      else "systemManagerModules";

    osNames = [os];

    # Apply one module value for one profile entry.
    # Returns [] when moduleValue is null, otherwise returns a one-element list.
    #
    # When moduleValue is a function whose formal parameters all carry
    # defaults (e.g. `{ admin ? false }: …`), it is treated as a
    # profile-options function and called with the supplied options — or
    # `{}` when the host lists the profile as a bare string, so that the
    # defaults take effect.
    applyProfileModule = entry: moduleValue:
      if moduleValue == null
      then []
      else let
        options =
          if entry.profileOptions == null
          then {}
          else entry.profileOptions;
        allDefaults =
          builtins.isFunction moduleValue
          && builtins.all lib.id (builtins.attrValues (builtins.functionArgs moduleValue));
        callWithOptions =
          builtins.isFunction moduleValue
          && (options != {} || allDefaults);
      in
        if callWithOptions
        then [(moduleValue options)]
        else if options != {}
        then throw "Profile '${entry.name}' does not accept profile options; use a string entry."
        else [moduleValue];

    featureModule = imports:
      if imports == []
      then null
      else {inherit imports;};

    # Resolve and apply both base and OS-specific module values for one entry.
    resolveEntry = entry: let
      profile = profiles.${entry.name} or (throw "Profile '${entry.name}' not found in flake.profiles");
      baseVal = profile.${moduleType};
      profileModules = lib.attrByPath ["modules"] [] profile;

      osVals =
        lib.concatMap (
          osName: let
            osVal = (profile.os.${osName} or {}).${moduleType} or null;
            osFeatureModules = lib.attrByPath ["os" osName "modules"] [] profile;
            osFeatureVal = featureModule (
              (collectFeatureModules {
                modules = profileModules;
                moduleType = featureModuleType;
                os = osName;
              })
              ++ (collectFeatureModules {
                modules = osFeatureModules;
                moduleType = featureModuleType;
              })
              ++ (collectFeatureModules {
                modules = osFeatureModules;
                moduleType = featureModuleType;
                os = osName;
              })
            );
          in
            applyProfileModule entry osFeatureVal
            ++ applyProfileModule entry osVal
        )
        osNames;

      # Merge order is:
      #
      # 1. base feature modules
      # 2. base profile module
      # 3. OS-specific feature modules + profile module (per osName)
      #
      # This gives "profile overrides module" and "OS overrides base", in case
      # multiple places set the same thing.
      baseFeatureVal = featureModule (
        collectFeatureModules {
          modules = profileModules;
          moduleType = featureModuleType;
        }
      );
    in
      applyProfileModule entry baseFeatureVal
      ++ applyProfileModule entry baseVal
      ++ osVals;
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
    ++ lib.optional (hostConfig.homeModule or null != null) hostConfig.homeModule
    ++ [
      {
        home = {
          inherit username;
          inherit (hostConfig) homeDirectory;
        };
      }
    ];

  mkHomeSopsModule = {hostConfig}: let
    sshKeyFile = inputs.secrets + "/${hostConfig.hostname}/user-ssh-key.yaml";
  in
    lib.recursiveUpdate
    {
      sops.age.keyFile = "${hostConfig.homeDirectory}/.config/sops/age/keys.txt";
    }
    (lib.optionalAttrs (builtins.pathExists sshKeyFile) {
      sops.secrets.ssh-private-key = {
        sopsFile = sshKeyFile;
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519";
      };
    });

  mkSystemSopsModule = {
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };

  # Construct the specialArgs attrset passed to home-manager modules. Provides
  # access to flake inputs, host metadata, and the canonical flake path.
  mkHomeSpecialArgs = {
    hostConfig,
    hostname,
    system,
    inputs,
    extraArgs ? {},
  }: let
    defaultFlakePath = "${hostConfig.homeDirectory}/dev/random/dotfiles/nix";
    flakePath =
      if (hostConfig.flakePath or null) != null
      then hostConfig.flakePath
      else defaultFlakePath;
  in
    {
      inherit
        hostname
        inputs
        system
        hostConfig
        flakePath
        ;
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
      ++ [
        inputs.sops-nix.homeManagerModules.sops
        (mkHomeSopsModule {inherit hostConfig;})
      ]
      ++ extraModules;
    extraSpecialArgs = mkHomeSpecialArgs {
      inherit
        hostConfig
        hostname
        system
        ;
      inherit inputs;
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
  inherit
    discoverModules
    fileNames
    hosts
    importNixFiles
    mkHomeConfiguration
    mkModules
    mkProjectShells
    mkSystemSopsModule
    ;
}
