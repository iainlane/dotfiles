{
  flake.modules.voxtype.os = {
    darwin = {
      homeManagerModules = [./darwin.nix];
      systemManagerModules = [./darwin-system.nix];
    };
    linux.homeManagerModules = [./linux.nix];
    nixos.homeManagerModules = [./linux.nix];
  };
}
