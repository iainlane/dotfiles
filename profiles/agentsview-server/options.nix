{lib, ...}: let
  common = import ../../lib/agentsview.nix {inherit lib;};
in {
  options.services.agentsview-server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to hold the shared archive of agent sessions and serve a
        dashboard over it. Machines with the `agentsview` profile push to it.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "pg.example.com";
      description = ''
        Hostname the database answers to. It has to reach this host directly,
        without a CDN in between, because what arrives is not HTTP.

        Machines reading it push here, so changing it means redeploying them
        too.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.submodule {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            example = "agents.example.com";
            description = "Hostname the dashboard is served under.";
          };

          auth = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Whether to make people sign in before the dashboard is served.
              It shows every machine's sessions, so this should stay on.
            '';
          };
        };
      };
      description = "Where the dashboard is served, which is ordinary web traffic.";
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = common.serverDefaults.database;
      readOnly = true;
      description = ''
        Database the sessions are kept in. Fixed, for the same reason as
        `user`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the dashboard listens on inside its container.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      example = "ancaster/host-agentsview.yaml";
      description = ''
        File in the secrets repository holding the database superuser's
        password. Each pushing machine has a role and a password of its own,
        under `agentsview-postgres/<machine>.yaml`; this one is the account
        those roles are created with.

        The dashboard connects with it over a URL, so generate it with
        `openssl rand -hex 32`. One containing `/`, `#`, `?` or `:` is parsed
        as a port or a path and the dashboard refuses to start.
      '';
    };
  };
}
