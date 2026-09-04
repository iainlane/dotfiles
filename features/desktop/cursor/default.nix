{
  flake.features.desktop.provides.cursor.os = {
    "generic-linux".homeManager = ./home-manager-linux.nix;
    nixos.homeManager = ./home-manager-linux.nix;
    darwin.homeManager = ./home-manager-darwin.nix;
  };
}
