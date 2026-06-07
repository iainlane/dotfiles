{inputs, ...}: let
  nixbuild = import ../nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.profiles.nixbuild-substituter = {
    inherit (nixbuild) homeManagerModule;

    os = {
      darwin.systemManagerModule = _: nixbuild.darwinSystemManagerModule;
      linux.systemManagerModule = _: nixbuild.linuxSystemManagerModule;
      nixos.nixosModule = _: nixbuild.nixosModule;
    };
  };
}
