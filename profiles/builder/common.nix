# Common builder profile module shared between system-manager (linux.nix) and
# NixOS (nixos.nix). Configures nixbuild.net as a remote builder with sops
# secrets and binary cache.
{lib}: let
  nixbuild = import ./nixbuild-common.nix {inherit lib;};
in {
  inherit nixbuild;

  module = {config, ...}: {
    imports = [
      nixbuild.module
    ];

    dotfiles.nix.binaryCaches."${nixbuild.builderAlias}" = nixbuild.binaryCaches."${nixbuild.builderAlias}";

    environment.etc."nix/machines".text =
      nixbuild.machineLines [
        "x86_64-linux"
        "aarch64-linux"
        "armv7l-linux"
      ]
      config.sops.secrets.nixbuild-private-key.path;

    nix.settings = {
      builders-use-substitutes = true;
    };
  };
}
