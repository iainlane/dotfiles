{lib, ...}: let
  modelType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "The model to download, as `ollama pull` would take it.";
      };

      aliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["baai/bge-m3"];
        description = ''
          Additional names for this model, for a caller that expects a name
          Ollama's own library does not use for these weights. Each alias is
          created with `ollama create` from a Modelfile that starts with
          `FROM` this model and sets {option}`parameters`.
        '';
      };

      parameters = lib.mkOption {
        type = lib.types.attrsOf (lib.types.oneOf [lib.types.int lib.types.float lib.types.str]);
        default = {};
        example = {num_batch = 8192;};
        description = ''
          Modelfile parameters for this model's aliases. Requests for an alias
          use these values. Requests for the model's own name keep the
          defaults from Ollama's library.
        '';
      };
    };
  };
in {
  options.dotfiles.inference.ollama = {
    requireAcceleration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Require GPU acceleration before scheduled local AgentsView index builds.
        Set this to false to permit CPU inference on this machine.
      '';
    };

    models = lib.mkOption {
      type = lib.types.listOf (lib.types.coercedTo lib.types.str (name: {inherit name;}) modelType);
      default = [];
      example = [
        "qwen3:4b"
        {
          name = "bge-m3";
          aliases = ["baai/bge-m3"];
        }
      ];
      description = ''
        Models to download with `ollama pull` whenever this configuration is
        activated. Search for models at <https://ollama.com/library>. A plain
        string pulls that model. A `{name, aliases, parameters}` set also
        creates each alias with those parameters.
      '';
    };
  };
}
