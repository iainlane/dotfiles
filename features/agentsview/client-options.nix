{
  config,
  lib,
  ...
}: {
  options.dotfiles.agentsview = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        The port the local dashboard listens on. It binds 127.0.0.1, so only
        this machine can reach it.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.agentsview";
      description = ''
        The directory containing the archive, the logs and `config.toml`.
        Every AgentsView command on this machine reads the same directory.
      '';
    };

    disabledAgents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Session providers that AgentsView excludes from local filesystem
        discovery. Existing archived sessions remain available.
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
          feature keeps its sessions locally and does not push.
        '';
      };
    };

    vector = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = ''
        Whether this machine builds a semantic-search embedding index over
        its archive and pushes it alongside the rest. The value comes from
        the host record: a machine with the `agentsview.embeddings` child
        feature does; one without it does not.
      '';
    };
  };
}
