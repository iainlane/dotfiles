{
  pkgs,
  lib,
  ...
}: let
  keyFile = "/not-present/anthropic-api-key";

  evaluate = modules:
    (lib.evalModules {
      modules = [./provider-credentials.nix] ++ modules;
    }).config.dotfiles;

  teamclaude = {
    imports = [./claude-code/teamclaude/anthropic-api-key.nix];
    options.dotfiles.claudeCode.teamclaude.apiKeyAccounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {};
    };
  };

  configured.dotfiles.ai.anthropicApiKeyFile = keyFile;
  accounts = modules: (evaluate ([teamclaude] ++ modules)).claudeCode.teamclaude.apiKeyAccounts;

  failures = lib.runTests {
    testUnsetWithoutTeamClaude = {
      expr = evaluate [];
      expected.ai = {
        anthropicApiKeyFile = null;
        openaiApiKeyFile = null;
        openrouterApiKeyFile = null;
      };
    };
    testConfiguredWithoutTeamClaude = {
      expr = evaluate [configured];
      expected.ai = {
        anthropicApiKeyFile = keyFile;
        openaiApiKeyFile = null;
        openrouterApiKeyFile = null;
      };
    };
    testUnsetWithTeamClaude = {
      expr = accounts [];
      expected = {};
    };
    testConfiguredWithTeamClaude = {
      expr = accounts [configured];
      expected.anthropic.apiKeyFile = keyFile;
    };
    testTeamClaudeAccountOverride = {
      expr = accounts [
        configured
        {
          dotfiles.claudeCode.teamclaude.apiKeyAccounts = {
            anthropic.apiKeyFile = "/not-present/teamclaude-key";
            spare.apiKeyFile = "/not-present/spare-key";
          };
        }
      ];
      expected = {
        anthropic.apiKeyFile = "/not-present/teamclaude-key";
        spare.apiKeyFile = "/not-present/spare-key";
      };
    };
  };
in {
  ai-credentials =
    pkgs.runCommandLocal "ai-credentials" {
      failures = builtins.toJSON failures;
    } ''
      if [[ $failures != '[]' ]]; then
        printf '%s\n' "$failures" >&2
        exit 1
      fi
      touch "$out"
    '';
}
