{
  flake.features.inference.provides.ollama = {
    nixos = ./nixos.nix;
    homeManager.imports = [./home-manager-options.nix];
    kernel.darwin.homeManager = ./home-manager.nix;
    kernel.linux.homeManager = ./home-manager-linux.nix;
  };
}
