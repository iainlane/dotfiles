{lib, ...}: {
  options.dotfiles.hermes.embeddings = {
    provider = lib.mkOption {
      type = lib.types.str;
      default = "openai-compatible";
      example = "voyage";
      description = ''
        LCM embedding provider. `openai-compatible` works with any endpoint
        that implements OpenAI's `/v1/embeddings`.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      example = "baai/bge-m3";
      description = "Embedding model identifier accepted by the configured endpoint.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "https://openrouter.ai/api/v1";
      description = ''
        API root for the `openai-compatible` provider, to which LCM appends
        `/embeddings`.
      '';
    };

    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = "LCM_EMBEDDING_API_KEY";
      example = "OPENROUTER_API_KEY";
      description = ''
        Environment variable from which the `openai-compatible` provider reads
        the API key. Point it at a variable that `secretEnv` already provides
        to share a key with the agent's models.
      '';
    };
  };
}
