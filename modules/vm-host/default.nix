{
  flake.modules."vm-host" = {
    nixosModules = [./nixos.nix];
  };
}
