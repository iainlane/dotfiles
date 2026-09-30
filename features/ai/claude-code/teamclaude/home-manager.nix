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
        refreshed tokens to it, so Nix does not manage the file.
      '';
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
        inherit (cfg) configFile;
        teamclaude = cfg.package;
      };
      description = ''
        The command that the user service runs. It starts the proxy when
        `configFile` lists at least one account.
      '';
    };
  };

  config = {
    home.packages = [cfg.package];

    programs.claude-code.package = packages.claude {
      inherit (cfg) configFile;
      claudeCode = config.dotfiles.claudeCode.package;
      teamclaude = cfg.package;
    };
  };
}
