{lib, ...}: {
  options.programs.agentsview = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this machine keeps an archive of its agent sessions and
        shows a dashboard of it. The archive is a SQLite database under
        `~/.agentsview`. AgentsView makes the archive from the session files
        of each agent and updates it as the agents write.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        The port of the dashboard. It binds 127.0.0.1, thus only this
        machine reaches it.
      '';
    };

    sync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        description = ''
          Whether this machine also pushes its archive to the shared
          database. The dashboard on the server then shows its sessions with
          the sessions of the other machines. If this is off, the archive
          stays on this machine and only this machine reads it.

          The value comes from the host record. A machine with the `work`
          profile keeps its sessions and does not push.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = ''
          The maximum time between pushes. AgentsView pushes each change as
          it occurs. This interval also pushes on a machine where the file
          watches failed.
        '';
      };
    };
  };
}
