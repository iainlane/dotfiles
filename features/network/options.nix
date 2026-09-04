{
  lib,
  nixosModulesPath,
  pkgs,
  utils,
  ...
}: {
  options.dotfiles.network = lib.mkOption {
    default = {};

    type = lib.types.submoduleWith {
      specialArgs = {inherit pkgs utils;};

      modules = [
        (nixosModulesPath + "/system/boot/networkd.nix")
        ./networkd-stubs.nix
        ./lan-address.nix
        {systemd.network.enable = true;}
      ];
    };

    description = ''
      The links, devices and networks systemd-networkd manages on this host,
      under `systemd.network` as NixOS declares it. Every option NixOS's
      networkd module offers is available; the feature renders the files and
      nothing else of that module reaches this host.

      `lanAddress` is derived from what is set here.
    '';
  };
}
