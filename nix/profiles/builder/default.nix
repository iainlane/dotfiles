{inputs, ...}: let
  nixbuild = import ./nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  imports = [
    ./linux.nix
    ./nixos.nix
    ./darwin.nix
  ];

  flake.profiles.builder.homeManagerModule = {
    dotfiles.ssh.matchBlocks = nixbuild.adminMatchBlocks;
  };
}
