# Direnv shell aggregation and flake option declaration.
#
# The compatibility output derives from legacyPackages. The `direnv-shells`
# package builds every flat direnv shell.
{
  lib,
  config,
  ...
}: {
  options.flake.direnvs = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = {};
    description = ''
      Nested direnv shells organised by system and directory path.
      Used by the project-directories home-manager module to generate
      .envrc files.
    '';
  };

  config.flake.direnvs = lib.genAttrs config.systems (system: config.flake.legacyPackages.${system}.direnvs or {});

  config.perSystem = {
    config,
    pkgs,
    ...
  }: {
    packages.direnv-shells = pkgs.linkFarm "direnv-shells" (
      lib.mapAttrsToList (name: drv: {
        inherit name;
        path = drv;
      })
      (lib.filterAttrs (name: _: lib.hasPrefix "direnvs-" name) config.devShells)
    );
  };
}
