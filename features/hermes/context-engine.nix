# The LCM context engine: swaps the default compressor for the hermes-lcm
# plugin and the Python packages it needs.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  config = lib.mkIf (cfg."context-engine" == "lcm") {
    services.hermes-agent = {
      extraPlugins.hermes-lcm = inputs.hermes-lcm;
      # hermes-lcm uses tiktoken for exact token counts and regex for
      # message ignore patterns. The vector store imports numpy lazily to
      # vectorise its top-k scan, and falls back to pure Python without it.
      extraPythonPackages =
        [
          pkgs.python312Packages.tiktoken
          pkgs.python312Packages.regex
        ]
        ++ lib.optional cfg.embeddings.enable pkgs.python312Packages.numpy;
      enabledPlugins = ["hermes-lcm"];
      settings.context.engine = "lcm";

      environment = lib.mkIf cfg.embeddings.enable (
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
