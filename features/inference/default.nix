{config, ...}: let
  children = config.flake.features.inference.provides;
in {
  imports = [
    ./ollama
    ./open-webui
  ];

  flake.features.inference = {
    includes = with children; [ollama open-webui];

    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
