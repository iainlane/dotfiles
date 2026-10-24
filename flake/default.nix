{inputs, ...}: let
  discovery = import ../lib/discovery.nix {inherit (inputs.nixpkgs) lib;};
in {
  imports =
    discovery.discoverModules ./.
    ++ discovery.discoverModuleFiles ../hosts
    ++ discovery.discoverModules ../features;
}
