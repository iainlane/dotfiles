{
  flake.features.inference.provides.ollama = {
    nixos = ./nixos.nix;
    homeManager.imports = [./home-manager-options.nix ./home-manager.nix];
  };
}
