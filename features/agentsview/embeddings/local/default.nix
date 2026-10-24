# Switches `agentsview.embeddings` from OpenRouter to a local Ollama server:
# free and unauthenticated, at the cost of running the model on this machine.
{
  config,
  lib,
  featureResolver,
  ...
}: let
  common = import ../../common.nix {
    inherit lib;
    inherit (config.dotfiles) features;
  };

  inherit (config.dotfiles) features;
in {
  dotfiles.flakeSystem.includes = [features.agentsview.embeddings.local];
  dotfiles.features.agentsview.embeddings.local = {
    checks = [./probe-check.nix (import ./gates-check.nix {inherit features featureResolver;})];
    includes = [
      (featureResolver.when featureResolver.isLinux [{checks = import ./host-check.nix {inherit features;};}])
      features.agentsview.embeddings
      features.inference.ollama
    ];

    homeManager = {
      config.dotfiles.inference.ollama.models = [
        {
          name = common.embeddings.defaultModel.ollamaName;
          aliases = [common.embeddings.defaultModel.name];
          # llama.cpp must fit each input to a BERT embedding model such as
          # bge-m3 into one batch. AgentsView sends chunks of up to 8192
          # characters, which can exceed Ollama's default batch of 2048
          # tokens. Ollama then truncates or rejects the chunk.
          parameters.num_batch = common.embeddings.defaultModel.contextTokens;
        }
      ];
    };
  };
}
