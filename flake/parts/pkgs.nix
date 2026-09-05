# Expose packages defined under `pkgs/` as `flake.packages.<system>.<name>`, so
# they can be built directly with `nix build .#<name>`. The underlying
# derivations are added to nixpkgs by `overlays/local-pkgs.nix`; this module
# surfaces them on the flake.
{lib, ...}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  names = discovery.discoverPackages ../../pkgs;
in {
  perSystem = {pkgs, ...}: let
    available =
      lib.filterAttrs
      (_: lib.meta.availableOn pkgs.stdenv.hostPlatform)
      (lib.genAttrs names (name: pkgs.${name}));
  in {
    packages =
      available
      // {
        # One derivation over the whole set, so CI can build every package
        # this system can build in a single job and cannot fall out of step
        # with what `pkgs/` contains.
        local-packages = pkgs.linkFarm "local-packages" (
          lib.mapAttrsToList (name: path: {inherit name path;}) available
        );
      };
  };
}
