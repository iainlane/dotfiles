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
          Additional names `ollama cp` gives this model once it is pulled,
          for a caller that expects a name Ollama's own library does not use
          for these weights.
        '';
      };
    };
  };
in {
  options.dotfiles.inference.ollama.models = lib.mkOption {
    type = lib.types.listOf (lib.types.coercedTo lib.types.str (name: {
        inherit name;
        aliases = [];
      })
      modelType);
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
      string pulls that model; a `{name, aliases}` set also gives it each
      alias with `ollama cp`.
    '';
  };
}
