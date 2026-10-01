# Declares `flake.modelCatalog`, the model identifiers that the AI harnesses,
# the prompt-conformance suite and Hermes share. The OS adapters pass the
# catalogue to every class module as the `modelCatalog` special argument, and
# its `defaults` as `defaultModels`.
{lib, ...}: let
  anthropic.opus = "claude-opus-5-5";
  google.geminiPro = "Gemini 3.1 Pro (High)";
  openai = {
    astra = "gpt-6-astra";
    sol = "gpt-6.1-sol";
    terra = "gpt-5.6-terra";
  };
  openrouter.sol = "~openai/gpt-sol-latest";

  modelsByName = lib.types.attrsOf lib.types.nonEmptyStr;
in {
  options.flake.modelCatalog = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf modelsByName;
      options.defaults = lib.mkOption {
        type = modelsByName;
        description = "The default model for each provider. A tool that has no reason to use a particular model is configured with the default for its provider.";
      };
    };
    description = "Model identifiers by provider and short name. A tool that selects a model refers to an entry here, so one edit changes every tool that uses that model.";
  };

  config.flake.modelCatalog = {
    inherit anthropic google openai openrouter;

    defaults = {
      anthropic = anthropic.opus;
      google = google.geminiPro;
      openai = openai.astra;
    };
  };
}
