# Expose packages defined under `pkgs/` as `flake.packages.<system>.<name>`, so
# they can be built directly with `nix build .#<name>`. The underlying
# derivations are added to nixpkgs by `overlays/local-pkgs.nix`; this module
# surfaces them on the flake, together with their tests.
{lib}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageOutputs = import ../../lib/package-outputs.nix {inherit lib;};
  names = discovery.discoverPackages ../../pkgs;
in
  {pkgs, ...}: let
    outputs = packageOutputs.forPlatform pkgs.stdenv.hostPlatform (lib.genAttrs names (name: pkgs.${name}));
  in
    outputs
    // {
      packages =
        outputs.packages
        // {
          local-packages = pkgs.linkFarm "local-packages" (lib.mapAttrsToList (name: path: {inherit name path;}) outputs.packages);
        };
    }
