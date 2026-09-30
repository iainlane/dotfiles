# The resolver that turns a host's feature list into the modules for one
# module system.
#
# A feature can define a module, or a list of modules, for each of NixOS,
# nix-darwin, system-manager and Home Manager. Its `system` field contributes
# modules to whichever of NixOS, nix-darwin and system-manager builds the
# host, and its `includes` field lists the features that it pulls in.
# `closure` expands those includes into an ordered list of the given features
# and everything that they include, and `modulesFor` selects one class of module
# from that list.
{lib}: let
  operatingSystems = import ./operating-systems.nix;
in rec {
  systemClassFor = os: operatingSystems.${os}.systemClass;

  # The kernel of a host, taken from the last component of its Nix system
  # string. NixOS and the Linux hosts built by system-manager share `linux`.
  kernelFor = system: lib.last (lib.splitString "-" system);

  # An evaluated `flake.features` entry. The entries are plain submodule
  # configs, so the check looks for the attributes common to every entry.
  featureType = lib.mkOptionType {
    name = "feature";
    description = "feature from flake.features";
    descriptionClass = "noun";
    check = value: lib.isAttrs value && value ? name && value ? includes;
    merge = lib.mergeEqualOption;
  };

  # An entry of `includes` that applies only on some hosts. `condition` is a
  # feature or a list of features, and the entry applies on a host that has all
  # of them:
  #
  #   includes = [
  #     (when features.ai [features.ai.provides.cloudflare-mcp])
  #   ];
  #
  # `condition` can instead be a predicate. The resolver calls it with an
  # attribute set containing `hasFeature`, a function that returns whether the
  # host has a given feature, and applies the entry when the predicate returns
  # true. The predicate receives nothing else about the host, so an include
  # never depends on a host's settings.
  when = condition: includes: let
    required = lib.toList condition;
  in {
    _type = "conditional-include";
    predicate =
      if lib.isFunction condition
      then condition
      else
        assert lib.assertMsg (lib.all featureType.check required)
        "`when` takes a feature, a list of features or a predicate as its condition.";
          {hasFeature, ...}: lib.all hasFeature required;
    inherit includes;
  };

  isConditional = entry: (entry._type or null) == "conditional-include";

  conditionalType = lib.mkOptionType {
    name = "conditionalInclude";
    description = "conditional include made by `when`";
    descriptionClass = "noun";
    check = entry: isConditional entry && lib.all featureType.check entry.includes;
    merge = lib.mergeOneOption;
  };

  # Resolves `features` and their transitive includes into composition order.
  # Each feature comes after its own includes, and a feature reached more than
  # once appears once. The includes under `os.<os>` are followed only for the
  # host's OS. An include cycle is an error: `closure` throws and lists the
  # features in the cycle.
  #
  # A `when` condition asks about the host's features, and the walk does not
  # know them until it has finished. `closure` therefore walks repeatedly. The
  # first walk answers every `hasFeature` with false, and each later walk
  # answers it from the features that the walk before it found. The repetition
  # stops when two consecutive walks find the same features.
  #
  # Conditions given as features cannot make the walks run forever: each walk
  # finds at least the features that the walk before it found, and a host can
  # reach only finitely many features. A predicate can also ask for a feature to
  # be absent, and the walks can then return to an earlier set of features. The
  # walks would repeat from there forever, so `closure` throws when a walk finds
  # a set that an earlier walk found.
  #
  # `excludes` names features to drop. A dropped feature contributes no
  # modules, and the walk does not follow its includes, so a feature that
  # nothing else includes is dropped with it. The result is `ordered`, the
  # remaining features in composition order, and `excluded`, the names that
  # the walk met and dropped. `excludeError` compares `excluded` with the host's
  # `excludes` to find an entry that dropped nothing.
  closure = {
    features,
    os,
    excludes ? [],
  }: let
    excludedNames = map (feature: feature.name) excludes;

    # `present` is the set of feature names that the previous walk found.
    resolveWith = present: let
      hasFeature = feature: present ? ${feature.name};

      expand = entry:
        if isConditional entry
        then lib.optionals (entry.predicate {inherit hasFeature;}) entry.includes
        else [entry];

      includesOf = feature:
        lib.concatMap expand
        (feature.includes ++ lib.attrByPath ["os" os "includes"] [] feature);

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
    in
      lib.foldl' (state: feature: walk state [] feature) {
        seen = {};
        ordered = [];
        excluded = [];
      }
      features;

    namesOf = result: lib.genAttrs (map (feature: feature.name) result.ordered) (_: true);

    # `earlier` lists the sets of names that the walks before `present` found.
    resolveFrom = earlier: present: let
      result = resolveWith present;
      resolved = namesOf result;
    in
      if resolved == present
      then result
      else if lib.elem resolved earlier
      then throw "Resolving ${lib.concatStringsSep ", " (map (feature: feature.name) features)} returned to a set of features that an earlier walk found, so the walks would repeat forever. A `when` predicate probably requires a feature to be absent, and its own includes add that feature."
      else resolveFrom (earlier ++ [present]) resolved;

    result = resolveFrom [] (namesOf (resolveWith {}));
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
  # feature is an entry of `flake.features`, so a name missing from the
  # registry is an evaluation error where the caller writes it.
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
