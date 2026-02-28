{lib, ...}: let
  moduleOptions = {
    homeManagerModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
    systemManagerModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
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
