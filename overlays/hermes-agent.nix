# hermes-agent's flake builds its packages with its own nixpkgs. That nixpkgs
# follows ours, but it does not take our overlays, so the nodejs-slim_26 patch
# in overlays/nodejs.nix does not reach the nodejs that hermes-agent uses.
#
# The package declares `callPackage` as an argument and uses it to build its
# sub-packages. Pass ours so those sub-packages resolve nodejs from this package
# set. The flake still chooses the package contents and the dependency groups.
{inputs}: final: prev: {
  hermes-agent = inputs.hermes-agent.packages.${prev.stdenv.hostPlatform.system}.default.override {
    inherit (final) callPackage;
  };
}
