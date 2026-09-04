{
  flake.features.desktop.provides.usbguard.nixos = [
    ./options.nix
    ./nixos.nix
  ];
}
