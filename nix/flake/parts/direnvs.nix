# Direnv shell aggregation and flake option declaration.
#
# This module:
# 1. Declares the `flake.direnvs` option that profiles contribute to
# 2. Creates a `direnv-shells` package that depends on all direnv shells,
#    allowing them to be pre-built with `nix build .#direnv-shells`
{lib, ...}: let
  # A type that recursively merges attribute sets from multiple modules.
  # This allows multiple profiles to contribute nested shells under the same
  # path prefixes (e.g., both can add to direnvs.aarch64-darwin.dev.*).
  recursiveAttrs = lib.mkOptionType {
    name = "recursiveAttrs";
    description = "recursively merged attribute set";
    check = lib.isAttrs;
    merge = _loc: defs:
      lib.foldl' lib.recursiveUpdate {} (map (def: def.value) defs);
  };
in {
  options.flake.direnvs = lib.mkOption {
    type = recursiveAttrs;
    default = {};
    description = ''
      Nested direnv shells organised by system and directory path.
      Used by the project-directories home-manager module to generate
      .envrc files.
    '';
  };

  config.perSystem = {
    pkgs,
    config,
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
