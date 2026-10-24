{config, ...}: let
  children = config.dotfiles.features.inference;
in {
  imports = [
    ./acceleration
    ./ollama
    ./open-webui
  ];

  dotfiles.features.inference = {
    includes = with children; [ollama open-webui];

    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
