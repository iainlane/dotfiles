{lib, ...}: {
  options.flake.nix = lib.mkOption {
    type = lib.types.submodule {
      options = {
        substitutersModule = lib.mkOption {
          type = lib.types.nullOr lib.types.unspecified;
          default = null;
        };
        substituterConfig = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };
    default = {};
  };
}
