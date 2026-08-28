{
  flake.modules.voxtype.os = {
    darwin.homeManagerModules = [./darwin.nix];
    linux.homeManagerModules = [./linux.nix];
    nixos.homeManagerModules = [./linux.nix];
  };
}
