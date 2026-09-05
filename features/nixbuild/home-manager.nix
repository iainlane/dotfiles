{
  config,
  hostConfig,
  inputs,
  lib,
  ...
}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  options.dotfiles.nixbuild.admin = lib.mkEnableOption "the nixbuild.net admin key and its SSH host alias";

  config = lib.mkMerge [
    {
      programs.ssh.settings = nixbuild.storeMatchBlock;
    }
    (lib.mkIf config.dotfiles.nixbuild.admin {
      sops.secrets.nixbuild-admin-private-key = {
        sopsFile = inputs.secrets + "/nixbuild-admin.yaml";
        key = "nixbuild_admin_private_key";
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild_admin";
      };

      programs.ssh.settings = nixbuild.adminMatchBlock;
    })
  ];
}
