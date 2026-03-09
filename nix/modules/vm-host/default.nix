_: let
  nixosModule = {
    username,
    ...
  }: {
    virtualisation.libvirtd = {
      enable = true;
      qemu.swtpm.enable = true;
    };

    programs.virt-manager.enable = true;

    users.users.${username}.extraGroups = ["libvirtd"];
  };
in {
  flake.modules."vm-host" = {
    nixosModules = [nixosModule];
  };
}
