# Register QEMU as a binfmt_misc interpreter for aarch64-linux on x86_64 hosts,
# allowing nix to build aarch64-linux derivations locally.
{inputs, ...}: let
  nixbuild = import ./nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.profiles.builder.os.linux.systemManagerModule = {
    config,
    lib,
    pkgs,
    hostConfig,
    ...
  }: {
    imports = [
      nixbuild.module
    ];

    dotfiles.nix.binaryCaches."${nixbuild.builderAlias}" = nixbuild.binaryCaches."${nixbuild.builderAlias}";

    environment.etc = lib.mkMerge [
      {
        "nix/machines".text =
          nixbuild.machineLines [
            "x86_64-linux"
            "aarch64-linux"
            "armv7l-linux"
          ]
          config.sops.secrets.nixbuild-private-key.path;
      }
      (lib.mkIf (hostConfig.arch == "x86_64") {
        "binfmt.d/aarch64-linux.conf".text = let
          targetSystem = "aarch64-linux";
          binfmtMagics = import (pkgs.path + "/nixos/lib/binfmt-magics.nix");
          targetMagic = binfmtMagics.${targetSystem};
          targetPlatform = lib.systems.elaborate {system = targetSystem;};
          interpreter = targetPlatform.emulator pkgs.pkgsStatic;
        in ":${targetSystem}:M::${targetMagic.magicOrExtension}:${targetMagic.mask}:${interpreter}:FPC";
      })
    ];

    environment.systemPackages = lib.optionals (hostConfig.arch == "x86_64") [pkgs.pkgsStatic.qemu-user];

    nix.settings = lib.mkMerge [
      {
        builders-use-substitutes = true;
      }
      (lib.mkIf (hostConfig.arch == "x86_64") {
        extra-platforms = ["aarch64-linux"];
      })
    ];

    systemd.services.sops-install-secrets = {
      before = ["sysinit-reactivation.target"];
      requiredBy = ["sysinit-reactivation.target"];
    };
  };
}
