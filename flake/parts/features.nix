# Declares `flake.features`, and publishes `lib/features.nix` as the
# `featureResolver` module argument so every reader of the registry uses one
# instance of it.
#
# A feature contributes a module, or a list of modules, to each module system
# that it configures, and it can include other features. Hosts and other
# features refer to entries by value, so a reference to a feature that does
# not exist fails at the reference.
#
# A feature also registers the concerns that only it uses, as children under
# `provides`. A child has every field of a feature, and its name is qualified
# by its parent's, so `closure` and `hasFeature` treat it like any other
# feature. Registering a child does not apply it: something has to list it in
# `includes`.
{lib, ...}: let
  featureResolver = import ../../lib/features.nix {inherit lib;};
  inherit (featureResolver) featureType includeType;

  # A module for one module system, or a list of them. Several files may
  # define the same class of the same feature; every definition ends up in
  # the imports of one module, each tagged with the file that defined it so
  # the module system reports errors against that file.
  #
  # `deferredModule` does the collecting and the tagging, but it cannot be
  # extended in place. `lib.types.coercedTo` refuses a source type whose
  # `getSubModules` is not null, and `fixupOptionType` rebuilds such a type
  # through `substSubModules`, which drops the `check` and `merge` added here.
  # So this type is declared on its own and passes one definition per module
  # to `deferredModule`'s merge, flattening a list first so a listed module is
  # tagged like one written on its own.
  classModule = let
    isModule = lib.types.deferredModule.check;
  in
    lib.mkOptionType {
      name = "classModule";
      description = "module, or list of modules";
      descriptionClass = "noun";
      check = value:
        isModule value
        || (lib.isList value && lib.all isModule value);
      merge = loc: defs:
        lib.types.deferredModule.merge loc (
          lib.concatMap
          (def: map (value: def // {inherit value;}) (lib.toList def.value))
          defs
        );
    };

  classOption = description:
    lib.mkOption {
      type = lib.types.nullOr classModule;
      default = null;
      inherit description;
    };

  includesOption = lib.mkOption {
    type = lib.types.listOf includeType;
    default = [];
    description = "Features and inline fragments to compose. Conditional entries use the selection context. Includes precede their parent.";
  };

  classOptions = lib.mapAttrs (_: class: classOption class.description) featureResolver.classes;

  featureModule = parentName: {name, ...}: let
    qualifiedName =
      if parentName == null
      then name
      else "${parentName}.${name}";
  in {
    options =
      classOptions
      // {
        name = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = qualifiedName;
          description = "The feature's key in `flake.features`, prefixed with its parent's name when it is a child.";
        };

        includes = includesOption;

        provides = lib.mkOption {
          type = lib.types.lazyAttrsOf (lib.types.submodule (featureModule qualifiedName));
          default = {};
          description = "Features registered by this one. Registering a child does not apply it: a host lists it in `features`, or a feature lists it in `includes`.";
        };
      };
  };
in {
  options.flake = {
    features = lib.mkOption {
      type = lib.types.lazyAttrsOf (lib.types.submodule (featureModule null));
      default = {};
      description = "Features that hosts list and that other features include.";
    };

    outputFeatures = lib.mkOption {
      type = lib.types.listOf featureType;
      default = [];
      description = "Features whose shared outputs are exported independently of host selection.";
    };
    outputExcludes = lib.mkOption {
      type = lib.types.listOf featureType;
      default = [];
      description = "Features excluded from the shared output selection.";
    };
  };

  config._module.args = {inherit featureResolver;};
}
