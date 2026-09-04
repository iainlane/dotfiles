{
  config,
  lib,
  ...
}: let
  cfg = config.services.hermes-agent;
in {
  options.services.hermes-agent.smallModel = lib.mkOption {
    type = lib.types.nonEmptyStr;
    default = "gpt-5.6-terra";
    description = "Default model for approval reviews, MCP sampling and session titles. Other auxiliary tasks inherit the main model.";
  };

  config.services.hermes-agent.settings.auxiliary = lib.genAttrs ["approval" "mcp" "title_generation"] (_: {
    model = lib.mkDefault cfg.smallModel;
  });
}
