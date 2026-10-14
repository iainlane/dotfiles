{
  config,
  lib,
  pkgs,
  ...
}: let
  herdr = config.programs.herdr.package;
  socket = "${config.xdg.configHome}/herdr/herdr.sock";
in {
  systemd.user.services.herdr = {
    Unit = {
      Description = "Herdr server";
      # Restarting the server ends every process in its panes.
      X-SwitchMethod = "keep-old";
    };

    Service = {
      # A `herdr` client starts a server of its own when none is running. When
      # that server has the socket, the condition skips this start, so the
      # unit does not fail and restart every 30 seconds.
      ExecCondition = "${pkgs.bash}/bin/bash -c '! ${lib.getExe pkgs.socat} -u OPEN:/dev/null UNIX-CONNECT:${socket} 2>/dev/null'";
      ExecStart = "${lib.getExe herdr} server";
      Restart = "on-failure";
      RestartSec = 30;
      # Herdr saves the session as it stops.
      TimeoutStopSec = 60;
    };

    Install.WantedBy = ["default.target"];
  };

  # The server can start before the desktop session imports its display
  # variables into the user manager, and its panes then have no display. A
  # shell in such a pane copies the variables from the user manager.
  programs.zsh.initContent = ''
    if [[ ''${HERDR_ENV:-} == 1 && -z ''${WAYLAND_DISPLAY:-} && -z ''${DISPLAY:-} ]]; then
      () {
        local line
        for line in ''${(f)"$(systemctl --user show-environment 2>/dev/null)"}; do
          case ''${line%%=*} in
            DISPLAY | WAYLAND_DISPLAY | XAUTHORITY | XDG_CURRENT_DESKTOP | XDG_SESSION_TYPE)
              export "$line"
              ;;
          esac
        done
      }
    fi
  '';
}
