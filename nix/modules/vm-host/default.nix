{config, ...}: let
  nixosModule = {
    username,
    pkgs,
    ...
  }: {
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
        ovmf.packages = [
          (pkgs.OVMF.override {
            secureBoot = true;
            tpmSupport = true;
          }).fd
        ];
      };
    };

    programs.virt-manager.enable = true;

    users.users.${username}.extraGroups = ["libvirtd"];
  };
in {
  flake.modules."vm-host" = {
    nixosModules = [nixosModule];
  };
}
