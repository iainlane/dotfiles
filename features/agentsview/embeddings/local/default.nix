# Switches `agentsview.embeddings` from OpenRouter to a local Ollama server:
# free and unauthenticated, at the cost of running the model on this machine.
{
  config,
  lib,
  ...
}: let
  common = import ../../common.nix {
    inherit lib;
    inherit (config.flake) features;
  };

  inherit (config.flake) features;
in {
  flake.features.agentsview.provides.embeddings.provides.local = {
    includes = [
      features.agentsview.provides.embeddings
      features.inference.provides.ollama
    ];

    homeManager = {
      config.dotfiles.inference.ollama.models = [
        {
          name = common.embeddings.backends.local.ollamaModel;
          aliases = [common.embeddings.model];
        }
      ];
    };
  };
}
