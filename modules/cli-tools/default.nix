{
  flake.modules."cli-tools" = {
    homeManagerModules = [./home-manager.nix];
    os.linux.homeManagerModules = [./linux.nix];
    os.nixos.homeManagerModules = [./linux.nix];
  };
}
