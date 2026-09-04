{
  flake.features.gnome = {
    nixos = [
      ./nixos.nix
      ./usbguard.nix
    ];
    os.nixos.homeManager = ./home-manager.nix;
  };
}
