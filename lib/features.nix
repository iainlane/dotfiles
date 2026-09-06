# The resolver that turns a host's feature list into the modules for one
# module system.
#
# A feature can define a module, or a list of modules, for each of NixOS,
# nix-darwin, system-manager and Home Manager. Its `system` field contributes
# modules to whichever of NixOS, nix-darwin and system-manager builds the
# host, and its `includes` field names the features it pulls in. `closure`
# expands those includes into an ordered list, which contains the features it
# was given as well as the ones they include, and `modulesFor` selects one
# class of module from that list.
{lib}: let
  operatingSystems = import ./operating-systems.nix;
in rec {
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

  # Resolves `features` and their transitive includes into composition order.
  # Each feature comes after the features it includes, and a feature reached
  # more than once appears once. The includes under `os.<os>` are followed
  # only for the host's OS. An include cycle is an error: `closure` throws and
  # names the features in the cycle.
  #
  # `excludes` names features to drop. A dropped feature contributes no
  # modules, and the walk does not follow its includes, so a feature that
  # nothing else includes is dropped with it. The result is `ordered`, the
  # remaining features in composition order, and `excluded`, the names the
  # walk met and dropped. `excludeError` compares `excluded` with the host's
  # `excludes` to find an entry that dropped nothing.
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

  # An error message for an `excludes` entry the host's composition cannot act
  # on, or null when every entry excludes something. A feature the host also
  # lists directly is asked for and refused at the same time. A feature the
  # closure never includes changes nothing, and is usually a typo or a
  # leftover.
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
    then "Host '${name}' excludes features not reached during feature resolution: ${lib.concatStringsSep ", " unreached}."
    else null;

  featureNames = args: map (feature: feature.name) (closure args).ordered;

  # Whether the host has the feature, directly or through an include. The
  # feature is an entry of `flake.features`, so a name the registry does not
  # have is an evaluation error where the caller writes it.
  hasFeature = hostConfig: feature: lib.elem feature.name hostConfig.featureNames;

  # The modules of class `class` from `ordered`, a closure's feature list.
  #
  # Each feature contributes, in order: its `<class>` module, its `system`
  # module when `class` is the module system that builds this OS, and its
  # `kernel.<kernel>` and `os.<os>` modules for that class. Only
  # `homeManager` is declared inside those two scopes, so the last two are
  # empty for every other class. The module system's merge functions and
  # priorities decide which definition of an option wins; this order does
  # not.
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
