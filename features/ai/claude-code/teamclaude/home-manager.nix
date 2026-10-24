{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.claudeCode.teamclaude;

  packages = pkgs.callPackage ./packages.nix {};
in {
  options.dotfiles.claudeCode.teamclaude = {
    configFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.xdg.configHome}/teamclaude.json";
      description = ''
        TeamClaude's config file. TeamClaude writes its accounts and their
        refreshed tokens to it. Activation reconciles the declared settings
        and API-key accounts without replacing OAuth credentials.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.json {}).type;
      default = {};
      example.switchThreshold = 0.98;
      description = ''
        Settings merged into the writable configuration at activation and
        server startup. Declared values override runtime values; undeclared
        settings and OAuth credentials remain unchanged. Use apiKeyAccounts
        to configure API-key accounts.
      '';
    };

    apiKeyAccounts = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          apiKeyFile = lib.mkOption {
            type = lib.types.str;
            description = "Path to a user-readable file containing the Anthropic API key.";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Rotation priority. Lower values are preferred; subscription accounts default to zero.";
          };
        };
      });
      description = ''
        API-key accounts indexed by account name. Keys are read at activation
        and server startup. Removing an entry removes its managed runtime
        account. Other account fields, such as disabled, remain unchanged.
      '';
    };

    provision = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = packages.provision {
        inherit (cfg) configFile settings apiKeyAccounts;
        teamclaude = cfg.package;
        waitForSops = pkgs.stdenv.hostPlatform.isDarwin && cfg.apiKeyAccounts != {} && (config.sops.secrets or {}) != {};
      };
      description = "The command that reconciles declared settings and API-key accounts.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = packages.cli {
        inherit (cfg) configFile;
        inherit (pkgs) teamclaude;
      };
      description = "The `teamclaude` CLI, which uses `configFile` unless `TEAMCLAUDE_CONFIG` is set.";
    };

    server = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = packages.server {
        inherit (cfg) configFile provision;
        teamclaude = cfg.package;
      };
      description = ''
        The command that the user service runs. It starts the proxy when
        `configFile` lists at least one account.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !(cfg.settings ? accounts);
        message = "Configure TeamClaude accounts through dotfiles.claudeCode.teamclaude.apiKeyAccounts, not settings.accounts.";
      }
    ];

    home.activation.teamclaudeConfig = lib.hm.dag.entryAfter ["writeBoundary" "sops-nix"] ''
      $DRY_RUN_CMD ${lib.getExe cfg.provision}
    '';

    home.packages = [cfg.package];

    programs.claude-code.package = packages.claude {
      inherit (cfg) configFile;
      claudeCode = config.dotfiles.claudeCode.package;
      teamclaude = cfg.package;
    };
  };
}
