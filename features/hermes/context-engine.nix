# The LCM context engine: swaps the default compressor for the hermes-lcm
# plugin and the Python packages it needs.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;

  # Extra packages share the agent's import path and must use its Python
  # interpreter. Derive the package set from the agent's interpreter argument
  # so an upstream interpreter update also applies to these packages.
  agentPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;

  interpreterArguments =
    lib.filter (lib.hasPrefix "python3")
    (lib.attrNames (lib.functionArgs agentPackage.override));

  pythonPackages =
    if lib.length interpreterArguments == 1
    then pkgs.${lib.head interpreterArguments}.pkgs
    else
      throw ''
        The hermes-agent package is expected to take one python3 interpreter
        argument, and takes ${toString (lib.length interpreterArguments)}.
        features/hermes/context-engine.nix picks the package set for
        `extraPythonPackages` from that argument's name.
      '';
in {
  config = lib.mkIf (cfg.contextEngine == "lcm") {
    dotfiles.hermes = {
      extraPlugins.hermes-lcm = inputs.hermes-lcm;
      # hermes-lcm uses tiktoken for exact token counts and regex for
      # message ignore patterns. The vector store imports numpy lazily to
      # vectorise its top-k scan, and falls back to pure Python without it.
      extraPythonPackages =
        [
          pythonPackages.tiktoken
          pythonPackages.regex
        ]
        ++ lib.optional cfg.embeddings.present pythonPackages.numpy;
      settings = {
        context.engine = "lcm";
        plugins.enabled = ["hermes-lcm"];
      };

      environment = lib.mkIf cfg.embeddings.present (
        {
          LCM_EMBEDDINGS_ENABLED = "true";
          LCM_EMBEDDING_PROVIDER = cfg.embeddings.provider;
          LCM_EMBEDDING_MODEL = cfg.embeddings.model;
          LCM_EMBEDDING_API_KEY_ENV = cfg.embeddings.apiKeyVariable;
          # `/lcm embed warmup` registers the model and its dimension and
          # `/lcm embed backfill` embeds the existing history. Neither is
          # reachable without the `/lcm` operator command, which LCM leaves
          # off by default.
          LCM_ENABLE_SLASH_COMMAND = "true";
        }
        # Only the openai-compatible provider takes an endpoint address.
        // lib.optionalAttrs (cfg.embeddings.baseUrl != "") {
          LCM_EMBEDDING_BASE_URL = cfg.embeddings.baseUrl;
        }
      );
    };
  };
}
