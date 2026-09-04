{
  flake.features.desktop.provides.gpg-agent = {
    homeManager = ./home-manager.nix;

    os = {
      "generic-linux".homeManager = ./home-manager-linux.nix;
      nixos.homeManager = ./home-manager-linux.nix;
      darwin.homeManager = ./home-manager-darwin.nix;
    };
  };
}
