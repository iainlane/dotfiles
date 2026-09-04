# The table of operating systems, and the resolver that turns a host's
# feature list into the modules for one module system.
#
# A feature is a set of modules, at most one for each of NixOS, nix-darwin,
# system-manager and Home Manager, and a list of features it includes.
# `closure` expands the includes into an ordered list and `modulesFor` reads
# one class of module from that list.
{lib}: rec {
  # Everything that varies by operating system and is not code: the module
  # system that builds the host's system configuration, the flake output that
  # configuration appears under, the directory the user's home lives in, and
  # the second half of the host's Nix system string. Adding an operating
  # system means adding an entry here and an adapter under `os/`.
  operatingSystems = {
    nixos = {
      systemClass = "nixos";
      outputName = "nixosConfigurations";
      homeBaseDir = "/home";
      systemSuffix = "linux";
    };

    "generic-linux" = {
      systemClass = "systemManager";
      outputName = "systemConfigs";
      homeBaseDir = "/home";
      systemSuffix = "linux";
    };

    darwin = {
      systemClass = "darwin";
      outputName = "darwinConfigurations";
      homeBaseDir = "/Users";
      systemSuffix = "darwin";
    };
  };

  systemClassFor = os: operatingSystems.${os}.systemClass;

  # The kernel a host runs, taken from the last component of its Nix system
  # string. NixOS and the Linux hosts system-manager builds share `linux`.
  kernelFor = system: lib.last (lib.splitString "-" system);

  # An evaluated `flake.features` entry. The entries are plain submodule
  # configs, so the check looks for the attributes every entry has.
  featureType = lib.mkOptionType {
    name = "feature";
    description = "feature from flake.features";
    descriptionClass = "noun";
    check = value: lib.isAttrs value && value ? name && value ? includes;
    merge = lib.mergeEqualOption;
  };

  # Expands `features` into every feature they include, directly or through
  # other features. Each feature comes after the features it includes, and a
  # feature reached more than once appears once. The includes under
  # `os.<os>` are followed only for the host's OS. An include cycle is an
  # error: `closure` throws and names the features in the cycle.
  #
  # `excludes` names features to drop. A dropped feature contributes no
  # modules and its own includes are not followed, so excluding a feature
  # also excludes whatever only it brings in. The result is `ordered`, the
  # features in composition order, and `excluded`, the names actually
  # dropped, which `excludeError` reads to tell an exclude that did nothing
  # from one that did.
  closure = {
    features,
    os,
    excludes ? [],
  }: let
    excludedNames = map (feature: feature.name) excludes;

    includesOf = feature:
      feature.includes ++ lib.attrByPath ["os" os "includes"] [] feature;

    walk = state: path: feature:
      if state.seen ? ${feature.name}
      then state
      else if lib.elem feature.name excludedNames
      then {
        seen = state.seen // {${feature.name} = true;};
        inherit (state) ordered;
        excluded = state.excluded ++ [feature.name];
      }
      else if lib.elem feature.name path
      then throw "Feature '${feature.name}' includes itself: ${lib.concatStringsSep " -> " (path ++ [feature.name])}"
      else let
        withIncludes =
          lib.foldl'
          (innerState: included: walk innerState (path ++ [feature.name]) included)
          state
          (includesOf feature);
      in {
        seen = withIncludes.seen // {${feature.name} = true;};
        ordered = withIncludes.ordered ++ [feature];
        inherit (withIncludes) excluded;
      };

    result =
      lib.foldl' (state: feature: walk state [] feature) {
        seen = {};
        ordered = [];
        excluded = [];
      }
      features;
  in {
    inherit (result) ordered excluded;
  };

  # The message for an `excludes` list the host's composition cannot act on,
  # or null when it can. A feature the host also lists is asked for and
  # refused at once; a feature the closure never reaches is a name that
  # changes nothing, usually a typo or a leftover.
  excludeError = {
    name,
    features,
    excludes,
    excluded,
  }: let
    excludedNames = map (feature: feature.name) excludes;

    listed = lib.intersectLists (map (feature: feature.name) features) excludedNames;

    unreached = lib.subtractLists excluded excludedNames;
  in
    if listed != []
    then "Host '${name}' both lists and excludes: ${lib.concatStringsSep ", " listed}."
    else if unreached != []
    then "Host '${name}' excludes features nothing on it includes: ${lib.concatStringsSep ", " unreached}."
    else null;

  featureNames = args: map (feature: feature.name) (closure args).ordered;

  # Whether the host has the feature called `name`, directly or through an
  # include.
  hasFeature = hostConfig: name: lib.elem name hostConfig.featureNames;

  # The modules of class `class` from `ordered`, a closure's feature list.
  #
  # Each feature contributes, in order: its `<class>` module, its `system`
  # module when `class` is the module system that builds this OS, its
  # `kernel.<kernel>.<class>` module, and its `os.<os>.<class>` module. The
  # module system's merge functions and priorities decide which definition of
  # an option wins; this order does not.
  modulesFor = {
    class,
    os,
    kernel,
    ordered,
  }: let
    systemClass = systemClassFor os;

    modulesOf = feature:
      lib.filter (module: module != null) (
        [feature.${class}]
        ++ lib.optional (class == systemClass) feature.system
        ++ [
          (lib.attrByPath ["kernel" kernel class] null feature)
          (lib.attrByPath ["os" os class] null feature)
        ]
      );
  in
    lib.concatMap modulesOf ordered;

  # The modules of class `class` for a host, refusing an `excludes` list its
  # composition cannot act on. Every class of every host goes through here,
  # so the refusal reaches whichever output is being built.
  resolveFeatures = {
    class,
    hostConfig,
  }: let
    resolved = closure {
      inherit (hostConfig) features os excludes;
    };

    error = excludeError {
      inherit (hostConfig) name features excludes;
      inherit (resolved) excluded;
    };
  in
    if error != null
    then throw error
    else
      modulesFor {
        inherit class;
        inherit (hostConfig) os;
        inherit (resolved) ordered;
        kernel = kernelFor hostConfig.system;
      };
}
