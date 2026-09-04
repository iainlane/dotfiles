# Aggregator for the flake's Nix helpers.
#
# The implementation is split by responsibility across sibling files; this
# module wires them together and re-exports the stable public surface that the
# rest of the flake imports as `helpers`. Prefer editing the focused files:
#
#   discovery.nix  filesystem discovery (hosts/features/packages)
#   features.nix   feature resolution: includes, ordering, per-class modules
#   home.nix       Home Manager module + specialArgs assembly
#   sops.nix       sops-nix module fragments
#   projects.nix   project shell / direnv generation
{inputs}: let
  inherit (inputs.nixpkgs) lib;

  discovery = import ./discovery.nix {inherit lib;};
  features = import ./features.nix {inherit lib;};
  sops = import ./sops.nix {inherit inputs lib;};
  home = import ./home.nix {
    inherit inputs lib;
    inherit (features) resolveFeatures;
    inherit (sops) mkHomeSopsModule;
  };
  projects = import ./projects.nix {inherit lib;};
in {
  inherit (discovery) discoverModules discoverModuleFiles discoverPackages fileNames importNixFiles;
  inherit (features) featureNames featureType hasFeature resolveFeatures;
  inherit (home) mkEmbeddedHomeManager mkHomeDefinition;
  inherit (sops) linuxSystemSopsModule systemSopsModule;
  inherit (projects) mkProjectShells;
}
