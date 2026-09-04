# The options of the server that stores the shared archive.
#
# `common` is `common.nix`, applied by `server.nix`: this file is a
# system-manager module, and the flake configuration `common.nix` needs is
# not among a system module's arguments.
{common}: {
  hostConfig,
  lib,
  options,
  ...
}: let
  presence = import ../../lib/presence.nix {inherit lib;};
in {
  options.dotfiles.agentsviewServer = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "pg.example.com";
      description = ''
        The hostname of the database. It must reach this host directly. A
        CDN between the two breaks it, because the traffic is not HTTP.

        The feature sets this from `flake.agentsviewServer.domain`, which the
        machines that push read too. If you change it, deploy them again.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.submodule (import ../../lib/exposed-service.nix);
      description = ''
        How the proxy serves the dashboard, which is web traffic. The
        dashboard shows the sessions of every machine, so leave `auth` on.
      '';
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = common.database;
      description = ''
        The database that holds the sessions. The machines that push read
        the same name from `common.nix` to build their connection URL, so a
        host that changes it here has to change it there as well.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "The port of the dashboard inside its container.";
    };

    backup.present = presence.option ''
      encrypted backups of the session database, uploaded to Cloudflare R2.
      `pg_dump` reads the database while it is serving, so the machines keep
      pushing while a backup runs
    '';

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-agentsview.yaml";
      description = ''
        The file in the secrets repository that holds the secrets of this
        machine. It needs four keys:

          agentsview_superuser_password: the account that makes the roles.
          agentsview_dashboard_password: the role that the dashboard reads
            the sessions as.
          ${common.authTokenSecret}: authenticates a caller to the API of
            the dashboard.
          ${common.cursorSecret}: signs the cursors of the dashboard.

        Each machine that pushes has a role and a password of its own, under
        `agentsview-postgres/<machine>.yaml`.

        Both passwords go into a URL. Make each one with
        `openssl rand -hex 32`. A password that contains `/`, `#`, `?` or `:`
        reads as a port or a path, and the dashboard does not start. Make the
        other two with `openssl rand -base64 32`.
      '';
    };
  };

  config.assertions = presence.assertions options [["dotfiles" "agentsviewServer" "backup" "present"]];
}
