{
  dotfiles.features.base.nix = {
    checks = [./nixpkgs-config-check.nix];
    homeManager = ./home-manager.nix;
  };
}
