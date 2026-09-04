# Turns a host's feature list into the modules for one module system.
#
# A feature is a set of modules, at most one for each of NixOS, nix-darwin,
# system-manager and Home Manager, and a list of features it includes.
# `closure` expands the includes into an ordered list and `modulesFor` reads
# one class of module from that list.
{lib}: rec {
  # The module system that builds a host's system configuration, keyed by the
  # host record's `os`.
  systemClasses = {
    nixos = "nixos";
    linux = "systemManager";
    darwin = "darwin";
  };

  systemClassFor = os: systemClasses.${os};

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
  closure = {
    features,
    os,
  }: let
    includesOf = feature:
      feature.includes ++ lib.attrByPath ["os" os "includes"] [] feature;

    walk = state: path: feature:
      if state.seen ? ${feature.name}
      then state
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
      };

    result =
      lib.foldl' (state: feature: walk state [] feature) {
        seen = {};
        ordered = [];
      }
      features;
  in
    result.ordered;

  featureNames = args: map (feature: feature.name) (closure args);

  # Whether the host has the feature called `name`, directly or through an
  # include.
  hasFeature = hostConfig: name: lib.elem name hostConfig.featureNames;

  # The modules of class `class` from `features` and everything they include.
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
    features,
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
    lib.concatMap modulesOf (closure {inherit features os;});

  resolveFeatures = {
    class,
    hostConfig,
  }:
    modulesFor {
      inherit class;
      inherit (hostConfig) os features;
      kernel = kernelFor hostConfig.system;
    };
}
