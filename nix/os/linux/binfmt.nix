# Register QEMU as a binfmt_misc interpreter for aarch64-linux on x86_64 hosts,
# allowing nix to build aarch64-linux derivations locally.
{
  lib,
  pkgs,
  hostConfig,
  ...
}:
lib.mkIf (hostConfig.arch == "x86_64") {
  environment.etc."binfmt.d/aarch64-linux.conf".text = let
    targetSystem = "aarch64-linux";
    binfmtMagics = import (pkgs.path + "/nixos/lib/binfmt-magics.nix");
    targetMagic = binfmtMagics.${targetSystem};
    targetPlatform = lib.systems.elaborate {system = targetSystem;};
    interpreter = targetPlatform.emulator pkgs.pkgsStatic;
  in ":${targetSystem}:M::${targetMagic.magicOrExtension}:${targetMagic.mask}:${interpreter}:FPC";

  environment.systemPackages = [pkgs.pkgsStatic.qemu-user];

  nix.settings.extra-platforms = ["aarch64-linux"];
}
