{
  imports = [
    ./linux.nix
    ./nixos.nix
  ];

  flake.profiles.containers.homeManagerModule = {};
}
