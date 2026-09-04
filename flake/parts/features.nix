# Declares `flake.features`.
#
# A feature is a module for each module system it configures and a list of
# the features it includes. Hosts and other features refer to entries by
# value, so a reference to a feature that does not exist fails at the
# reference.
{
  config,
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  # A module for one module system, or a list of them. Several files may
  # define the same class of the same feature; every definition ends up in
  # the imports of one module, each tagged with the file that defined it so
  # the module system reports errors against that file.
  classModule = lib.mkOptionType {
    name = "classModule";
    description = "module, or list of modules";
    descriptionClass = "noun";
    check = value: lib.isList value || lib.types.deferredModule.check value;
    merge = loc: defs: {
      imports =
        lib.concatMap
        (def:
          map
          (lib.setDefaultModuleLocation "${def.file}, via option ${lib.showOption loc}")
          (lib.toList def.value))
        defs;
    };
  };

  classOption = description:
    lib.mkOption {
      type = lib.types.nullOr classModule;
      default = null;
      inherit description;
    };

  includesOption = lib.mkOption {
    type = lib.types.listOf helpers.featureType;
    default = [];
    description = "Features to include when resolving this feature. Each included feature appears before this one in the resolved list.";
  };

  osScope = lib.types.submodule {
    options = {
      homeManager = classOption "Home Manager module applied only on hosts with this OS.";
      includes = includesOption;
    };
  };

  featureModule = {name, ...}: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = name;
        description = "The feature's key in `flake.features`.";
      };

      includes = includesOption;

      nixos = classOption "NixOS module.";
      darwin = classOption "nix-darwin module.";
      systemManager = classOption "system-manager module, for Linux hosts that are not NixOS.";
      homeManager = classOption "Home Manager module.";
      system = classOption "Module for whichever of NixOS, nix-darwin or system-manager builds the host.";

      os = lib.mkOption {
        type = lib.types.submodule {
          options = lib.genAttrs config.dotfiles.operatingSystems (_:
            lib.mkOption {
              type = osScope;
              default = {};
            });
        };
        default = {};
        description = "Modules and includes that apply only to hosts with this OS.";
      };
    };
  };
in {
  options.flake.features = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule featureModule);
    default = {};
    description = "Features that hosts list and that other features include.";
  };
}
