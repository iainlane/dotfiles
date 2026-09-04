{
  flake.features.desktop.provides.fonts = {
    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;

    # `nixos.nix` puts the same list in `fonts.packages`, so NixOS hosts must
    # not install these fonts in the user profile as well.
    os = {
      darwin.homeManager = ./home-manager-packages.nix;
      generic-linux.homeManager = ./home-manager-packages.nix;
    };
  };
}
