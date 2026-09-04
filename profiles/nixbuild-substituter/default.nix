{inputs, ...}: let
  nixbuild = import ../nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.features.nixbuild-substituter = {
    homeManager = nixbuild.homeManagerModule;
    darwin = nixbuild.darwinSystemManagerModule;
    systemManager = nixbuild.linuxSystemManagerModule;
    nixos = nixbuild.nixosModule;
  };
}
