{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
  modelCatalog = import ../ai/models.nix;
in {
  options.dotfiles.hermes.smallModel = lib.mkOption {
    type = lib.types.nonEmptyStr;
    default = modelCatalog.openai.terra;
    description = "Default model for approval reviews, inbox classification, MCP sampling and session titles. Other auxiliary tasks inherit the main model.";
  };

  config.dotfiles.hermes.settings.auxiliary = lib.genAttrs ["approval" "mcp" "title_generation"] (_: {
    model = lib.mkDefault cfg.smallModel;
  });
}
