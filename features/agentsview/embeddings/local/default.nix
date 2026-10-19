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
    inherit (config.flake) features;
  };

  inherit (config.flake) features;
in {
  flake.features.agentsview.provides.embeddings.provides.local = {
    checks = [./probe-check.nix (import ./gates-check.nix {inherit features featureResolver;})];
    includes = [
      (featureResolver.when featureResolver.isLinux [{checks = import ./host-check.nix {inherit features;};}])
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
