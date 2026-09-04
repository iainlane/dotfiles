{
  flake.features."cli-tools" = {
    homeManager = ./home-manager.nix;
    os.linux.homeManager = ./linux.nix;
    os.nixos.homeManager = ./linux.nix;
  };
}
