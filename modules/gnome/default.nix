{
  flake.modules.gnome = {
    nixosModules = [
      ./nixos.nix
      ./usbguard.nix
    ];
    os.nixos.homeManagerModules = [./home-manager.nix];
  };
}
