{
  flake.features.work.provides.falcon.nixos = [
    ./service.nix
    ./nixos.nix
  ];
}
