# Direnv shell aggregation and flake option declaration.
#
# Declares the `flake.direnvs` option that features contribute to, and builds a
# `direnv-shells` package depending on every direnv shell, so
# `nix build .#direnv-shells` pre-builds them all.
{lib, ...}: let
  # A type that recursively merges the attribute sets several modules define,
  # so more than one feature can contribute nested shells under the same path
  # prefix, such as `direnvs.aarch64-darwin.dev.*`.
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
