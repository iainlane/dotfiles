{config, ...}: let
  children = config.dotfiles.features.inference;
in {
  imports = [
    ./acceleration
    ./ollama
    ./librechat
    ./open-webui
  ];

  dotfiles.features.inference = {
    includes = with children; [ollama librechat];

    homeManager = ./home-manager.nix;
    nixos = ./nixos.nix;
  };
}
