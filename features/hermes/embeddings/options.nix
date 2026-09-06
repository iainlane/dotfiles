{lib, ...}: {
  options.dotfiles.hermes.embeddings = {
    provider = lib.mkOption {
      type = lib.types.str;
      default = "openai-compatible";
      example = "voyage";
      description = ''
        Embedding provider. `openai-compatible` targets any endpoint that
        serves OpenAI's `/v1/embeddings`; `voyage`, `ollama` and `fastembed`
        are the other providers LCM knows.
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
        Environment variable the `openai-compatible` provider reads the API
        key from. Naming a variable rather than the key itself lets a key
        already in `secretEnv` serve both the agent and the embedding
        endpoint.
      '';
    };
  };
}
