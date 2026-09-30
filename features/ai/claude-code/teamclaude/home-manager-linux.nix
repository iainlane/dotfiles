{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.claudeCode.teamclaude;
in {
  systemd.user.services.teamclaude = {
    Unit.Description = "TeamClaude proxy for Claude Code";

    Service = {
      ExecStart = lib.getExe cfg.server;
      Restart = "on-failure";
      RestartSec = 10;
    };

    Install.WantedBy = ["default.target"];
  };

  # Starts the service after `teamclaude login` adds the first account.
  systemd.user.paths.teamclaude = {
    Unit.Description = "Start the TeamClaude proxy when its config changes";

    Path.PathChanged = cfg.configFile;

    Install.WantedBy = ["default.target"];
  };
}
