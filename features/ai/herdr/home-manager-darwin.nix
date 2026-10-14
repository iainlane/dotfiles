{config, ...}: let
  log = "${config.home.homeDirectory}/Library/Logs/herdr.log";
  socket = "${config.xdg.configHome}/herdr/herdr.sock";
in {
  launchd.agents.herdr = {
    enable = true;
    config = {
      # A `herdr` client starts a server of its own when none is running. When
      # that server has the socket, the agent exits successfully, and
      # `KeepAlive` does not start it again.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "/usr/bin/nc -U -z '${socket}' 2>/dev/null && exit 0; exec '${config.programs.herdr.package}/bin/herdr' server"
      ];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 30;
      StandardOutPath = log;
      StandardErrorPath = log;
    };
  };
}
