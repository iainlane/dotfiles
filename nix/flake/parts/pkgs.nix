# Expose packages defined under `pkgs/` as `flake.packages.<system>.<name>`, so
# they can be built directly with `nix build .#<name>`. The underlying
# derivations are added to nixpkgs by `overlays/local-pkgs.nix`; this module
# surfaces them on the flake.
{
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  names = helpers.discoverPackages ../../pkgs;
in {
  perSystem = {pkgs, ...}: {
    packages = lib.genAttrs names (name: pkgs.${name});
  };
}
