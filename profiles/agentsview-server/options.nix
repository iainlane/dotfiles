{lib, ...}: let
  common = import ../../lib/agentsview.nix {inherit lib;};
in {
  options.services.agentsview-server = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this machine holds the shared archive of agent sessions and
        shows a dashboard of it. The machines with the `agentsview` profile
        push to this machine.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "pg.example.com";
      description = ''
        The hostname of the database. It must reach this host directly. A
        CDN between the two breaks it, because the traffic is not HTTP.

        The machines that push read this name. If you change it, deploy them
        again.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.submodule {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            example = "agents.example.com";
            description = "The hostname of the dashboard.";
          };

          auth = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Whether a person must sign in before the dashboard shows
              anything. The dashboard shows the sessions of all the machines,
              thus keep this on.
            '';
          };
        };
      };
      description = "The address of the dashboard, which is web traffic.";
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = common.serverDefaults.database;
      readOnly = true;
      description = ''
        The database that holds the sessions. The machines that push work
        this name out for themselves and cannot read it from here, thus it is
        fixed.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "The port of the dashboard inside its container.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      example = "ancaster/host-agentsview.yaml";
      description = ''
        The file in the secrets repository that holds the password of the
        database superuser. This account makes the roles.

        Each machine that pushes has a role and a password of its own, under
        `agentsview-postgres/<machine>.yaml`.

        The dashboard puts this password in a URL. Make it with
        `openssl rand -hex 32`. A password that contains `/`, `#`, `?` or `:`
        reads as a port or a path, and the dashboard does not start.
      '';
    };
  };
}
