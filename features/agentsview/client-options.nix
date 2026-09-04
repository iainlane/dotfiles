{
  config,
  lib,
  ...
}: {
  options.programs.agentsview = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        The port of the dashboard. It binds 127.0.0.1, thus only this
        machine reaches it.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.agentsview";
      description = ''
        The directory that holds the archive, the logs and `config.toml`.
        Every AgentsView command on this machine reads the same directory.
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
          feature keeps its sessions and does not push.
        '';
      };
    };
  };
}
