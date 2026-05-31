{
  config,
  lib,
  ...
}: let
  profileRequirementType = with lib.types;
    either str (submodule {
      options = {
        profile = lib.mkOption {
          type = str;
        };

        os = lib.mkOption {
          type = nullOr (listOf (enum config.dotfiles.operatingSystems));
          default = null;
        };
      };
    });

  moduleOptions = {
    homeManagerModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
    systemManagerModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
    nixosModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
    modules = lib.mkOption {
      type = with lib.types; listOf unspecified;
      default = [];
    };
    requires = lib.mkOption {
      type = with lib.types; listOf profileRequirementType;
      default = [];
    };
  };
in {
  options.flake.profiles = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options =
        moduleOptions
        // {
          os = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = moduleOptions;
            });
            default = {};
          };
        };
    });
    default = {};
  };
}
