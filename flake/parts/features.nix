# Declares `flake.features`.
#
# A feature is a module for each module system it configures and a list of
# the features it includes. Hosts and other features refer to entries by
# value, so a reference to a feature that does not exist fails at the
# reference.
#
# A feature also carries the concerns that only it uses, as children under
# `provides`. A child has every field a feature has and its name is qualified
# by its parent's, so `closure` and `hasFeature` treat it like any other
# feature. Registering a child does not apply it: something has to list it in
# `includes`.
{
  config,
  lib,
  ...
}: let
  inherit (import ../../lib/features.nix {inherit lib;}) featureType;

  # A module for one module system, or a list of them. Several files may
  # define the same class of the same feature; every definition ends up in
  # the imports of one module, each tagged with the file that defined it so
  # the module system reports errors against that file.
  #
  # `deferredModule` does the collecting and the tagging. It cannot be
  # extended in place: `lib.types.coercedTo` refuses a type whose
  # `getSubModules` is not null, and `fixupOptionType` rebuilds any type whose
  # `getSubModules` is not null through `substSubModules`, which discards
  # whatever was added to it. So this type is declared on its own and gives
  # `deferredModule`'s merge one definition per module, with the list flattened
  # first so a listed module and a module written on its own are tagged alike.
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
    type = lib.types.listOf featureType;
    default = [];
    description = "Features to include when resolving this feature. Each included feature appears before this one in the resolved list.";
  };

  osScope = lib.types.submodule {
    options = {
      homeManager = classOption "Home Manager module applied only on hosts with this OS.";
      includes = includesOption;
    };
  };

  kernelScope = lib.types.submodule {
    options = {
      homeManager = classOption "Home Manager module applied only on hosts with this kernel.";
    };
  };

  featureModule = parentName: {name, ...}: let
    qualifiedName =
      if parentName == null
      then name
      else "${parentName}.${name}";
  in {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = qualifiedName;
        description = "The feature's key in `flake.features`, prefixed with its parent's name when it is a child.";
      };

      includes = includesOption;

      nixos = classOption "NixOS module.";
      darwin = classOption "nix-darwin module.";
      systemManager = classOption "system-manager module, for Linux hosts that are not NixOS.";
      homeManager = classOption "Home Manager module.";
      system = classOption "Module for whichever of NixOS, nix-darwin or system-manager builds the host.";

      os = lib.mkOption {
        type = lib.types.submodule {
          options = lib.genAttrs config.flake.operatingSystems (_:
            lib.mkOption {
              type = osScope;
              default = {};
            });
        };
        default = {};
        description = "Modules and includes that apply only to hosts with this OS.";
      };

      kernel = lib.mkOption {
        type = lib.types.submodule {
          options = lib.genAttrs ["linux" "darwin"] (_:
            lib.mkOption {
              type = kernelScope;
              default = {};
            });
        };
        default = {};
        description = "Modules that apply only to hosts with this kernel. NixOS and the Linux hosts system-manager builds share the `linux` scope.";
      };

      provides = lib.mkOption {
        type = lib.types.lazyAttrsOf (lib.types.submodule (featureModule qualifiedName));
        default = {};
        description = "Features this one carries. A child is applied where a feature lists it in `includes`, not by registering it here.";
      };
    };
  };
in {
  options.flake.features = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule (featureModule null));
    default = {};
    description = "Features that hosts list and that other features include.";
  };
}
