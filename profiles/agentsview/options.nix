{lib, ...}: {
  options.programs.agentsview = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to keep an archive of this machine's agent sessions and serve
        a dashboard over it. The archive is a SQLite database under
        `~/.agentsview`, built by reading the session files each agent leaves
        behind and kept up to date as they are written.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port the dashboard listens on. It binds 127.0.0.1, so it is reachable
        from this machine alone.
      '';
    };

    sync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        description = ''
          Whether to also push this machine's archive to the shared database,
          so its sessions appear in the dashboard alongside every other
          machine's. Off leaves the archive where it is, readable only here.

          Read off the host record: a machine with the `work` profile keeps
          its sessions and pushes nothing.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = ''
          How long to wait before pushing anyway, having seen nothing change.
          Changes are noticed as they happen; this is what covers a machine
          whose watches were exhausted or missed.
        '';
      };
    };
  };
}
