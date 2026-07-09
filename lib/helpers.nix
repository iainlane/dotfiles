# Aggregator for the flake's Nix helpers.
#
# The implementation is split by responsibility across sibling files; this
# module wires them together and re-exports the stable public surface that the
# rest of the flake imports as `helpers`. Prefer editing the focused files:
#
#   discovery.nix  filesystem discovery (hosts/profiles/modules/packages)
#   hosts.nix      host record loading
#   profiles.nix   profile normalisation, validation, module resolution
#   home.nix       Home Manager module + specialArgs assembly
#   sops.nix       sops-nix module fragments
#   projects.nix   project shell / direnv generation
{inputs}: let
  inherit (inputs.nixpkgs) lib;

  discovery = import ./discovery.nix {inherit lib;};
  hosts = import ./hosts.nix {inherit lib discovery;};
  profiles = import ./profiles.nix {inherit lib;};
  sops = import ./sops.nix {inherit inputs lib;};
  home = import ./home.nix {
    inherit inputs lib;
    inherit (profiles) mkModules;
    inherit (sops) mkHomeSopsModule;
  };
  projects = import ./projects.nix {inherit lib;};
in {
  inherit (discovery) discoverModules discoverPackages fileNames importNixFiles;
  inherit (hosts) hosts;
  inherit (profiles) activeProfileNames hasProfile mkModules validateProfileRequirements;
  inherit (home) mkHomeConfiguration;
  inherit (sops) mkSystemSopsModule;
  inherit (projects) mkProjectShells;
}
