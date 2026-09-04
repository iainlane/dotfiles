{
  hostConfig,
  inputs,
  username,
  ...
}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  dotfiles.nix.binaryCaches."${nixbuild.builderAlias}" = nixbuild.binaryCaches."${nixbuild.builderAlias}";

  nix.settings = {
    builders-use-substitutes = true;
  };

  sops = {
    defaultSopsFile = inputs.secrets + "/nixbuild.yaml";
    secrets = {
      nixbuild-builder-private-key = {
        key = "nixbuild_private_key";
        owner = username;
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild";
        mode = "0400";
      };
      nixbuild-private-key = {
        key = "nixbuild_private_key";
        mode = "0400";
      };
      nixbuild-remote-store-private-key = {
        key = "nixbuild_remote_store_private_key";
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519_nixbuild_store";
        owner = username;
        mode = "0400";
      };
    };
  };
}
