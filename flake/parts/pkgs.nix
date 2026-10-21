# Expose packages defined under `pkgs/` as `flake.packages.<system>.<name>`, so
# they can be built directly with `nix build .#<name>`. The underlying
# derivations are added to nixpkgs by `overlays/local-pkgs.nix`; this module
# surfaces them on the flake, together with their tests.
{lib, ...}: let
  discovery = import ../../lib/discovery.nix {inherit lib;};
  packageOutputs = import ../../lib/package-outputs.nix {inherit lib;};
  names = discovery.discoverPackages ../../pkgs;
in {
  perSystem = {pkgs, ...}: let
    outputs = packageOutputs.forPlatform pkgs.stdenv.hostPlatform (lib.genAttrs names (name: pkgs.${name}));
  in {
    packages =
      outputs.packages
      // {
        # One derivation over every package available on this system, so CI
        # builds them in a single job and cannot fall out of step with what
        # `pkgs/` contains.
        local-packages = pkgs.linkFarm "local-packages" (
          lib.mapAttrsToList (name: path: {inherit name path;}) outputs.packages
        );
      };

    inherit (outputs) checks;
    legacyPackages.slowChecks = outputs.slowChecks;
  };
}
