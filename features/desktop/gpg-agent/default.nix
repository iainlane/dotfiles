{
  flake.features.desktop.provides.gpg-agent = {
    homeManager = ./home-manager.nix;

    kernel.linux.homeManager = ./home-manager-linux.nix;
    os.darwin.homeManager = ./home-manager-darwin.nix;
  };
}
