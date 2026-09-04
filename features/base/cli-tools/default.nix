{
  flake.features.base.provides.cli-tools = {
    homeManager = ./home-manager.nix;
    os."generic-linux".homeManager = ./home-manager-linux.nix;
    os.nixos.homeManager = ./home-manager-linux.nix;
  };
}
