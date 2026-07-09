# Profile and module resolution: the heart of the "host -> profiles ->
# features" contract. Hosts declare a list of profiles; each profile bundles a
# set of feature modules plus its own inline modules. These helpers normalise
# the host's profile entries, validate profile requirements, and resolve the
# selected profiles into the final list of modules for a given module type
# (Home Manager, system-manager, or NixOS).
{lib}: rec {
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

  # Names of the profiles active on `hostConfig`, normalised so that both
  # string entries (`"desktop"`) and option-bearing entries
  # (`{ desktop = { ... }; }`) collapse to a flat list of names.
  activeProfileNames = hostConfig:
    map (entry: entry.name) (normaliseProfileEntries hostConfig.profiles);

  # Predicate: is `name` one of the profiles selected by this host?
  hasProfile = hostConfig: name:
    builtins.elem name (activeProfileNames hostConfig);

  # Normalise profile requirements from either the shorthand string form:
  #
  #   requires = [ "containers" ];
  #
  # or the attrset form:
  #
  #   requires = [{ profile = "containers"; os = [ "linux" "nixos" ]; }];
  normaliseProfileRequirement = requirement:
    if builtins.isString requirement
    then {
      profile = requirement;
      os = null;
    }
    else requirement;

  profileRequirementApplies = hostConfig: requirement:
    requirement.os == null || builtins.elem hostConfig.os requirement.os;

  validateProfileRequirements = {
    hostConfig,
    profiles,
  }: let
    entries = normaliseProfileEntries hostConfig.profiles;
    activeNames = activeProfileNames hostConfig;
    hostLabel = hostConfig.hostname;

    mkRequirementError = entry: requirement:
      if requirement.profile == entry.name
      then "Host '${hostLabel}' profile '${entry.name}' cannot require itself"
      else if !(builtins.hasAttr requirement.profile profiles)
      then "Host '${hostLabel}' profile '${entry.name}' requires unknown profile '${requirement.profile}'"
      else if !(builtins.elem requirement.profile activeNames)
      then "Host '${hostLabel}' profile '${entry.name}' requires profile '${requirement.profile}'"
      else null;

    mkOsRequirementError = entry: requirement:
      if requirement.os == null
      then null
      else "Host '${hostLabel}' profile '${entry.name}' has an OS-scoped requirement with a nested os filter";

    profileRequirementErrors = entry: let
      profile = profiles.${entry.name} or (throw "Profile '${entry.name}' not found in flake.profiles");
      baseRequirements =
        builtins.filter
        (profileRequirementApplies hostConfig)
        (map normaliseProfileRequirement (profile.requires or []));
      osRequirements = map normaliseProfileRequirement ((profile.os.${hostConfig.os} or {}).requires or []);
      osRequirementErrors = builtins.filter (error: error != null) (map (mkOsRequirementError entry) osRequirements);
      scopedRequirements = builtins.filter (requirement: requirement.os == null) osRequirements;
      requirementErrors = builtins.filter (error: error != null) (map (mkRequirementError entry) (baseRequirements ++ scopedRequirements));
    in
      osRequirementErrors ++ requirementErrors;

    errors = lib.concatMap profileRequirementErrors entries;
  in
    if errors == []
    then true
    else throw (lib.concatStringsSep "\n" errors);

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
    moduleTypes = [
      "homeManagerModule"
      "systemManagerModule"
      "nixosModule"
    ];

    # Apply one module value for one profile entry.
    #
    # Profiles may include both plain modules (for example `{ imports = [...] ; }`)
    # and option-taking wrapper functions (for example `{ admin ? false }: ...`).
    # Host-supplied profile options are only applied to the wrapper functions.
    # Plain modules are still included unchanged so bundle-style profiles can
    # accept options without turning every imported feature module into a
    # wrapper function.
    applyProfileModule = entry: moduleValue: let
      options =
        if entry.profileOptions == null
        then {}
        else entry.profileOptions;
      acceptsProfileOptions =
        builtins.isFunction moduleValue
        && builtins.all lib.id (builtins.attrValues (builtins.functionArgs moduleValue));
    in
      if moduleValue == null
      then {
        consumedOptions = false;
        modules = [];
      }
      else if acceptsProfileOptions
      then {
        consumedOptions = options != {};
        modules = [(moduleValue options)];
      }
      else {
        consumedOptions = false;
        modules = [moduleValue];
      };

    profileAcceptsOptions = profile: let
      baseVals = map (type: profile.${type}) moduleTypes;
      osVals =
        lib.concatMap (
          osName:
            map (type: (profile.os.${osName} or {}).${type} or null) moduleTypes
        )
        osNames;
    in
      lib.any (
        moduleValue:
          builtins.isFunction moduleValue
          && builtins.all lib.id (builtins.attrValues (builtins.functionArgs moduleValue))
      )
      (baseVals ++ osVals);

    featureModule = imports:
      if imports == []
      then null
      else {inherit imports;};

    # Resolve and apply both base and OS-specific module values for one entry.
    resolveEntry = entry: let
      profile = profiles.${entry.name} or (throw "Profile '${entry.name}' not found in flake.profiles");
      baseVal = profile.${moduleType};
      profileModules = lib.attrByPath ["modules"] [] profile;

      options =
        if entry.profileOptions == null
        then {}
        else entry.profileOptions;

      osResults =
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
          in [
            (applyProfileModule entry osFeatureVal)
            (applyProfileModule entry osVal)
          ]
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
      baseResults = [
        (applyProfileModule entry baseFeatureVal)
        (applyProfileModule entry baseVal)
      ];
      allResults = baseResults ++ osResults;
      consumedOptions = lib.any (result: result.consumedOptions) allResults;
      acceptsOptions = profileAcceptsOptions profile;
    in
      if options != {} && !consumedOptions && !acceptsOptions
      then throw "Profile '${entry.name}' does not accept profile options; use a string entry."
      else lib.concatMap (result: result.modules) allResults;
  in
    lib.concatMap resolveEntry entries;
}
