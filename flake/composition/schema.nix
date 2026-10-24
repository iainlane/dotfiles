# Declares `dotfiles.features`, and publishes `lib/features.nix` as the
# `featureResolver` module argument so every reader of the registry uses one
# instance of it.
#
# A feature contributes a module, or a list of modules, to each module system
# that it configures, and it can include other features. Hosts and other
# features refer to entries by value, so a reference to a feature that does
# not exist fails at the reference.
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

  featureSubmodule = parentName:
    lib.types.submoduleWith {
      description = "feature";
      shorthandOnlyDefinesConfig = true;
      modules = [(featureModule parentName)];
    };

  featureModule = parentName: {name, ...}: let
    qualifiedName =
      if parentName == null
      then name
      else "${parentName}.${name}";
  in {
    freeformType = lib.types.lazyAttrsOf (featureSubmodule qualifiedName);
    options =
      classOptions
      // {
        name = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = qualifiedName;
          description = "The feature's key in `dotfiles.features`, prefixed with its parent's name when it is a child.";
        };

        includes = includesOption;
      };
  };
in {
  options.dotfiles = {
    features = lib.mkOption {
      type = lib.types.lazyAttrsOf (featureSubmodule null);
      default = {};
      description = "Named components and their explicitly selected children.";
    };
    flakeSystem = {
      includes = includesOption;
      excludes = lib.mkOption {
        type = lib.types.listOf featureType;
        default = [];
        description = "Features excluded from shared output composition.";
      };
    };
    inventorySchema = lib.mkOption {
      type = classModule;
      default = {};
      description = "Typed declarations available in each host's inventory.";
    };
  };

  config._module.args = {inherit featureResolver;};
}
