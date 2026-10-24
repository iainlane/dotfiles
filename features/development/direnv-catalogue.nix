{
  lib,
  config,
  ...
}: {
  options.flake.direnvs = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = {};
    description = "Nested direnv shells organised by system and directory path.";
  };
  config.flake.direnvs =
    lib.genAttrs config.systems
    (system: config.flake.legacyPackages.${system}.direnvs or {});
}
