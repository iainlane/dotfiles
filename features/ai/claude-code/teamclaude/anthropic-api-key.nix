{
  config,
  lib,
  ...
}: let
  apiKeyFile = config.dotfiles.ai.anthropicApiKeyFile;
in {
  imports = [../../provider-credentials.nix];

  config = lib.mkIf (apiKeyFile != null) {
    dotfiles.claudeCode.teamclaude.apiKeyAccounts.anthropic.apiKeyFile = lib.mkDefault apiKeyFile;
  };
}
