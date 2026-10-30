{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.claudeCode.teamclaude;
in {
  systemd.user = {
    services.teamclaude-frontend = lib.mkIf cfg.frontend.enable {
      Unit = {
        Description = "Claude API frontend before TeamClaude";
        After = ["teamclaude.service"];
        Wants = ["teamclaude.service"];
      };
      Service = {
        ExecStart = lib.getExe cfg.frontend.server;
        Restart = "on-failure";
        RestartSec = 10;
        UMask = "0077";
      };
      Install.WantedBy = ["default.target"];
    };

    services.teamclaude = {
      Unit = {
        Description = "TeamClaude proxy for Claude Code";
        After = ["sops-nix.service"];
      };

      Service = {
        ExecStart = lib.getExe cfg.server;
        Restart = "on-failure";
        RestartSec = 10;
      };

      Install.WantedBy = ["default.target"];
    };

    # Starts the service after `teamclaude login` adds the first account.
    paths.teamclaude = {
      Unit.Description = "Start the TeamClaude proxy when its config changes";

      Path.PathChanged = cfg.configFile;

      Install.WantedBy = ["default.target"];
    };
  };
}
