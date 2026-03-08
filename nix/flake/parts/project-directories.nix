{lib, ...}: {
  options.flake.projectDirectories = lib.mkOption {
    type = lib.types.submodule {
      options = {
        homeManagerModule = lib.mkOption {
          type = lib.types.nullOr lib.types.unspecified;
          default = null;
        };
      };
    };
    default = {};
  };
}
