{lib}: let
  operatingSystems = import ./operating-systems.nix;
  compositionArgs = ["platform" "hostConfig" "systemConfig" "homeConfig"];
  isConditionalEntry = entry: lib.isAttrs entry && (entry._type or null) == "conditional-include";
  selectEntries = applies: context: owner: entries:
    lib.concatLists (lib.imap0 (index: value: let
      identity = "${owner}/includes/${toString index}";
    in
      if isConditionalEntry value
      then lib.optionals (applies context value.predicate) (selectEntries applies context identity value.includes)
      else [{inherit identity value;}])
    entries);
in rec {
  classes = import ./feature-classes.nix {inherit lib;};
  outputClasses = lib.attrNames (lib.filterAttrs (_: class: class.kind == "output") classes);

  contextForSystem = system: {platform = lib.systems.elaborate system;};
  contextForHost = hostConfig:
    contextForSystem hostConfig.system
    // {
      inherit hostConfig;
      systemClass = operatingSystems.${hostConfig.os}.systemClass;
    };

  isLinux = {platform, ...}: platform.isLinux;
  isDarwin = {platform, ...}: platform.isDarwin;
  isAarch64 = {platform, ...}: platform.isAarch64;
  isx86_64 = {platform, ...}: platform.isx86_64;
  isNixos = {hostConfig, ...}: hostConfig.os == "nixos";
  isGenericLinux = {hostConfig, ...}: hostConfig.os == "generic-linux";
  isStable = {hostConfig, ...}: hostConfig.channel == "stable";
  isUnstable = {hostConfig, ...}: hostConfig.channel == "unstable";

  featureType = lib.mkOptionType {
    name = "feature";
    description = "feature from dotfiles.features";
    descriptionClass = "noun";
    check = value: lib.isAttrs value && value ? name && value ? includes;
    merge = lib.mergeEqualOption;
  };

  isConditional = isConditionalEntry;

  includeType = lib.mkOptionType {
    name = "featureInclude";
    description = "feature, fragment or conditional include";
    descriptionClass = "noun";
    check = value:
      featureType.check value
      || (isConditional value && lib.isFunction value.predicate && lib.isList value.includes && lib.all includeType.check value.includes)
      || (lib.isAttrs value
        && lib.all (key: key == "includes" || classes ? ${key}) (lib.attrNames value)
        && (!(value ? includes) || (lib.isList value.includes && lib.all includeType.check value.includes)));
    merge = location: definitions: let
      tag = file: entry:
        if isConditional entry
        then entry // {includes = map (tag file) entry.includes;}
        else if featureType.check entry
        then entry
        else
          lib.mapAttrs (field: value:
            if field == "includes"
            then map (tag file) value
            else if value == null
            then null
            else {
              _file = file;
              imports = lib.toList value;
            })
          entry;
    in
      lib.mergeOneOption location (map (definition: definition // {value = tag definition.file definition.value;}) definitions);
  };

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

  predicateApplies = context: predicate: let
    arguments = lib.functionArgs predicate;
    required = lib.attrNames (lib.filterAttrs (_: optional: !optional) arguments);
  in
    lib.all (argument: context ? ${argument}) required
    && predicate (
      if arguments == {}
      then context
      else lib.intersectAttrs arguments context
    );

  select = context: entries: map (entry: entry.value) (selectEntries predicateApplies context "<selection>" entries);

  closure = {
    features,
    context,
    excludes ? [],
  }: let
    excludedNames = map (feature: feature.name) excludes;

    resolveWith = present: let
      predicateContext = context // {hasFeature = feature: present ? ${feature.name};};

      walkEntries = state: path: owner: entries:
        lib.foldl' (current: entry: walk current path entry.identity entry.value)
        state (selectEntries predicateApplies predicateContext owner entries);

      walk = state: path: identity: entry: let
        registered = featureType.check entry;
        node =
          if registered
          then entry
          else
            entry
            // {
              name = identity;
              __fragment = true;
            };
        inherit (node) name;
      in
        if state.seen ? ${name}
        then state
        else if registered && lib.elem name excludedNames
        then {
          seen = state.seen // {${name} = true;};
          inherit (state) ordered;
          excluded = state.excluded ++ [name];
        }
        else if lib.elem name path
        then throw "Feature '${name}' includes itself: ${lib.concatStringsSep " -> " (path ++ [name])}"
        else let
          withIncludes = walkEntries state (path ++ [name]) name (node.includes or []);
        in {
          seen = withIncludes.seen // {${name} = true;};
          ordered = withIncludes.ordered ++ [node];
          inherit (withIncludes) excluded;
        };
    in
      walkEntries {
        seen = {};
        ordered = [];
        excluded = [];
      } [] "<selection>"
      features;

    namesOf = result:
      lib.genAttrs (map (feature: feature.name) (lib.filter (feature: !(feature.__fragment or false)) result.ordered)) (_: true);

    resolveFrom = earlier: present: let
      result = resolveWith present;
      resolved = namesOf result;
    in
      if resolved == present
      then result
      else if lib.elem resolved earlier
      then throw "Resolving ${lib.concatStringsSep ", " (map (feature: feature.name) features)} returned to a set of features that an earlier walk found, so the walks would repeat forever. A `when` predicate probably requires a feature to be absent, and its own includes add that feature."
      else resolveFrom (earlier ++ [present]) resolved;
  in
    resolveFrom [] (namesOf (resolveWith {}));

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

  resolveSelection = args @ {
    features,
    excludes ? [],
    name ? "outputs",
    ...
  }: let
    resolved = closure (removeAttrs args ["name"]);
    error = excludeError {
      inherit name features excludes;
      inherit (resolved) excluded;
    };
  in
    if error != null
    then throw error
    else resolved;

  featureNames = args:
    map (feature: feature.name) (lib.filter (feature: !(feature.__fragment or false)) (closure args).ordered);

  hasFeature = hostConfig: feature: lib.elem feature.name hostConfig.featureNames;

  contributionsFor = {
    class,
    context,
    ordered,
  }: let
    sources = lib.sort (a: b: classes.${a}.kind != "alias" && classes.${b}.kind == "alias") (lib.attrNames (lib.filterAttrs (_: entry: entry.destination context == class) classes));
  in
    lib.concatMap (feature:
      lib.concatMap (source:
        lib.imap0 (index: module: {
          inherit module;
          identity = "${feature.name}/${source}/${toString index}";
        })
        (lib.optionals ((feature.${source} or null) != null) (lib.toList feature.${source})))
      sources)
    ordered;

  modulesFor = args: map (entry: entry.module) (contributionsFor args);

  resolveFeatures = {
    class,
    hostConfig,
  }: let
    context = contextForHost hostConfig;
    resolved = resolveSelection {
      inherit context;
      inherit (hostConfig) name features excludes;
    };
  in
    modulesFor {
      inherit class context;
      inherit (resolved) ordered;
    };

  contextArguments = module:
    if lib.isFunction module
    then lib.intersectLists compositionArgs (lib.attrNames (lib.functionArgs module))
    else [];
}
