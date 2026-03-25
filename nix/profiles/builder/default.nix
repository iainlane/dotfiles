{inputs, ...}: let
  nixbuild = import ./nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  imports = [
    ./linux.nix
    ./nixos.nix
    ./darwin.nix
  ];

  flake.profiles.builder.homeManagerModule = {admin ? false}: {
    inputs,
    lib,
    ...
  }:
    lib.mkMerge [
      {
        dotfiles.ssh.matchBlocks = nixbuild.storeMatchBlock;
      }
      (lib.mkIf admin {
        sops.secrets.nixbuild-admin-private-key = {
          sopsFile = inputs.secrets + "/nixbuild-admin.yaml";
          key = "nixbuild_admin_public_key";
          path = "~/.ssh/id_ed25519_nixbuild_admin";
        };

        dotfiles.ssh.matchBlocks = nixbuild.adminMatchBlock;
      })
    ];
}
