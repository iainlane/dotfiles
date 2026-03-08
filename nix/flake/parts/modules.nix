{lib, ...}: let
  moduleListOption = lib.mkOption {
    type = with lib.types; listOf unspecified;
    default = [];
  };
in {
  options.flake.modules = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options = {
        homeManagerModules = moduleListOption;
        systemManagerModules = moduleListOption;
        os = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              homeManagerModules = moduleListOption;
              systemManagerModules = moduleListOption;
            };
          });
          default = {};
        };
      };
    });
    default = {};
  };
}
