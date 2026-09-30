{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.claudeCode.teamclaude;
  log = "${config.home.homeDirectory}/Library/Logs/teamclaude.log";
in {
  launchd.agents.teamclaude = {
    enable = true;
    config = {
      ProgramArguments = [(lib.getExe cfg.server)];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      # Starts the server after `teamclaude login` adds the first account.
      WatchPaths = [cfg.configFile];
      StandardOutPath = log;
      StandardErrorPath = log;
    };
  };
}
