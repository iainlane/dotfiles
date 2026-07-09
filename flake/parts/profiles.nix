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
    features = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      description = ''
        Feature names resolved against `flake.modules`. This is the preferred
        way for a profile to declare which feature modules it composes: names
        are validated (unknown names fail with a clear error) and keep
        `flake.profiles` declarative rather than carrying opaque module values.
      '';
    };
    modules = lib.mkOption {
      type = with lib.types; listOf unspecified;
      default = [];
      description = ''
        Legacy value-based feature list: raw `flake.modules.<name>` values
        included directly. Prefer `features` (name-based). Retained as a
        compatibility path; entries are appended after resolved `features`.
      '';
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
