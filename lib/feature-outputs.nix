{
  lib,
  inputs,
  featureResolver,
}: let
  channels = import ./channels.nix {inherit inputs;};
  flakeOptions = (inputs.flake-parts.lib.evalFlakeModule {inherit inputs;} {systems = [];}).options;
  nativeOptions = flakeOptions.perSystem.type.getSubOptions [];

  recursiveValue = lib.mkOptionType {
    name = "recursiveOutput";
    description = "recursively merged output";
    check = _: true;
    merge = location: definitions: let
      values = map (definition: definition.value) definitions;
    in
      if lib.all (value: lib.isAttrs value && !lib.isDerivation value) values
      then (lib.types.attrsOf recursiveValue).merge location definitions
      else if lib.all lib.isList values
      then lib.concatLists values
      else lib.mergeEqualOption location definitions;
  };

  typeFor = class:
    if class == "legacyPackages"
    then lib.types.lazyAttrsOf recursiveValue
    else nativeOptions.${class}.type;

  expand = identity: file: inheritedKey: module: let
    pathModule = builtins.isPath module || lib.isString module;
    loaded =
      if pathModule
      then import module
      else module;
    source =
      if pathModule
      then toString module
      else file;
    moduleKey =
      if pathModule
      then toString module
      else loaded.key or inheritedKey;
    wrapper = lib.isAttrs loaded && loaded ? imports && lib.all (key: lib.elem key ["imports" "_file" "key"]) (lib.attrNames loaded);
  in
    if wrapper
    then lib.concatLists (lib.imap0 (index: child: expand "${identity}/${toString index}" (loaded._file or source) "${moduleKey}:anon-${toString index}" child) loaded.imports)
    else [
      {
        inherit identity;
        key = moduleKey;
        module = loaded;
        file = source;
      }
    ];
in rec {
  contributions = args:
    lib.concatMap (entry: expand entry.identity "feature outputs" entry.identity entry.module) (featureResolver.contributionsFor args);

  needsHost = entry:
    lib.any (argument: lib.elem argument ["hostConfig" "systemConfig" "homeConfig"])
    (featureResolver.contextArguments entry.module);

  bind = context: entry: let
    arguments = featureResolver.contextArguments entry.module;
  in
    (lib.setDefaultModuleLocation entry.file (
      if arguments == []
      then entry.module
      else entry.module (lib.getAttrs arguments context)
    ))
    // {key = entry.key or entry.file;};

  evaluate = {
    class,
    modules,
    args ? {},
  }: let
    evaluated = lib.evalModules {
      inherit class;
      specialArgs = args;
      modules = [{_module.freeformType = typeFor class;}] ++ modules;
    };
  in
    removeAttrs evaluated.config ["_module"];

  merge = class: outputs:
    evaluate {
      inherit class;
      modules =
        map (output: {
          _file = output.file;
          config = output.value;
        })
        outputs;
    };

  forSystem = {
    pkgs,
    pkgs-stable,
    system,
    hosts,
    outputFeatures,
    outputExcludes,
    hostResults,
  }: let
    sharedContext = featureResolver.contextForSystem system;
    roots = featureResolver.resolveSelection {
      context = sharedContext;
      features = outputFeatures;
      excludes = outputExcludes;
    };
    nativeHosts = lib.filterAttrs (_: host: host.system == system) hosts;
    selections = map (host: {
      inherit host;
      context = featureResolver.contextForHost host;
      inherit
        ((featureResolver.resolveSelection {
          inherit (host) name;
          context = featureResolver.contextForHost host;
          inherit (host) features excludes;
        }))
        ordered
        ;
    }) (lib.attrValues nativeHosts);
    collect = class: selection:
      contributions {
        inherit class;
        inherit (selection) context ordered;
      };
    sharedFor = class: lib.unique (map (entry: entry.identity) sharedEntries.${class});
    sharedEntries = lib.genAttrs featureResolver.outputClasses (class:
      lib.filter (entry: !needsHost entry)
      (collect class {
          context = sharedContext;
          inherit (roots) ordered;
        }
        ++ lib.concatMap (collect class) selections));
    sharedModules = class:
      map (identity:
        bind sharedContext (lib.findFirst (entry: entry.identity == identity) null sharedEntries.${class})) (sharedFor class);
    sharedArgs = {inherit pkgs pkgs-stable system inputs;};
    forHost = class: selection: let
      inherit (selection) host ordered;
      context =
        selection.context
        // {
          systemConfig = hostResults.${host.name}.configuration.config;
          homeConfig = hostResults.${host.name}.homeConfiguration.config;
        };
      channel = channels.channelFor {
        inherit (host) channel;
        inherit pkgs pkgs-stable;
      };
    in
      evaluate {
        inherit class;
        modules = map (bind context) (lib.filter needsHost (contributions {inherit class context ordered;}));
        args = sharedArgs // {pkgs = channel.primary;};
      };
  in
    lib.genAttrs featureResolver.outputClasses (class:
      merge class ([
          {
            file = "${class} outputs for ${system}";
            value = evaluate {
              inherit class;
              modules = sharedModules class;
              args = sharedArgs;
            };
          }
        ]
        ++ map (selection: {
          file = "${class} outputs for host '${selection.host.name}' (${system})";
          value = forHost class selection;
        })
        selections));
}
