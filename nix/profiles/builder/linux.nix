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
  }: let
    x86Config = let
      targetSystem = "aarch64-linux";
      binfmtMagics = import (pkgs.path + "/nixos/lib/binfmt-magics.nix");
      targetMagic = binfmtMagics.${targetSystem};
      targetPlatform = lib.systems.elaborate {system = targetSystem;};
      interpreter = targetPlatform.emulator pkgs.pkgsStatic;
    in
      lib.mkIf (hostConfig.arch == "x86_64") {
        environment.etc."binfmt.d/aarch64-linux.conf".text =
          ":${targetSystem}:M::${targetMagic.magicOrExtension}:${targetMagic.mask}:${interpreter}:FPC";

        environment.systemPackages = [pkgs.pkgsStatic.qemu-user];

        nix.settings.extra-platforms = ["aarch64-linux"];
      };
  in
    lib.mkMerge [
      {
        environment.etc = {
          "nix/machines".text =
            nixbuild.machineLines nixbuild.systems
            config.sops.secrets.nixbuild-private-key.path;
          "ssh/ssh_config.d/100-nixbuild.conf".text = nixbuild.sshConfigText;
          "ssh/ssh_known_hosts".text = "${nixbuild.hostName} ${nixbuild.hostKey}";
        };
      }
      x86Config
    ]
    // {
      imports = [
        nixbuild.module
      ];
    };
}
