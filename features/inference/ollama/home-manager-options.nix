{lib, ...}: {
  options.dotfiles.inference.ollama.models = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["bge-m3" "qwen3:4b"];
    description = ''
      Models to download with `ollama pull` whenever this configuration is
      activated. Search for models at <https://ollama.com/library>.
    '';
  };
}
