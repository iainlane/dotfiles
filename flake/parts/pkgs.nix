# Expose packages defined under `pkgs/` as `flake.packages.<system>.<name>`, so
# they can be built directly with `nix build .#<name>`. The underlying
# derivations are added to nixpkgs by `overlays/local-pkgs.nix`; this module
# surfaces them on the flake.
{lib, ...}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  names = discovery.discoverPackages ../../pkgs;
in {
  perSystem = {pkgs, ...}: {
    packages =
      lib.filterAttrs
      (_: lib.meta.availableOn pkgs.stdenv.hostPlatform)
      (lib.genAttrs names (name: pkgs.${name}));
  };
}
