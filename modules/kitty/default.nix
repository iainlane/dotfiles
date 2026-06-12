{
  flake.modules.kitty = {
    homeManagerModules = [./home-manager.nix];
    os = {
      darwin.homeManagerModules = [./darwin.nix];
      linux.homeManagerModules = [./linux.nix];
      nixos.homeManagerModules = [./linux.nix];
    };
  };
}
