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
    nixosModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
    darwinModule = lib.mkOption {
      type = lib.types.nullOr lib.types.unspecified;
      default = null;
    };
  };
in {
  options.flake.os = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = moduleOptions;
    });
    default = {};
  };
}
