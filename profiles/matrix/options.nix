{lib, ...}: {
  options.services.continuwuity = {
    serverName = lib.mkOption {
      type = lib.types.str;
      example = "matrix.orangesquash.org.uk";
      description = ''
        The homeserver's `server_name`: the domain suffix of every user and room
        ID (`@someone:<serverName>`). It is baked into all identifiers and
        cannot be changed once accounts and rooms exist, so choose carefully.
      '';
    };

    botUsername = lib.mkOption {
      type = lib.types.str;
      example = "godfrey";
      description = ''
        Local part of the account the homeserver creates at startup for the
        agent to log in as. The password comes from `matrix_password` in
        `secretsFile`.
      '';
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          passwordKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Key in `secretsFile` holding the password to create this account
              with. Null for an account that already exists, or one registered
              from a client with the registration token. The password must not
              contain whitespace (it travels through a whitespace-split admin
              command); anything else, such as the output of
              `openssl rand -base64 24`, is fine.
            '';
          };

          admin = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Grant this account server-admin rights, needed to run `!admin`
              commands (such as creating further users) from a Matrix client.
            '';
          };

          supportUser = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Publish this account at `/.well-known/matrix/support`. The
              homeserver publishes one contact, so at most one account may set
              this. With none set it publishes everyone in the admin room, the
              agent's account among them.
            '';
          };
        };
      });
      default = {};
      example = lib.literalExpression ''{ iain.admin = true; }'';
      description = ''
        Accounts the homeserver acts on at startup, keyed by local username
        (`@<name>:<serverName>`). An account with a `passwordKey` is created,
        and one with `admin` is granted server-admin rights whether or not it
        was created here. The agent's own account is always created.
      '';
    };

    backup = {
      enable = lib.mkEnableOption "periodic online backups of the database";

      keep = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "How many backups to retain before the oldest is deleted.";
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 03:30:00";
        description = "When to take a backup, in the format of systemd.time(7).";
      };
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      example = "ancaster/host-matrix.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file holding
        `matrix_password` (the password the agent's account is created with),
        `matrix_registration_token` (the token that gates registration, entered
        in a Matrix client to create accounts) and every `passwordKey` named in
        `provisionUsers`. The homeserver runs as a system service, so this file
        is encrypted to the host key.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      example = lib.literalExpression ''{ admins_list = ["@iain:example.org"]; }'';
      description = ''
        Extra keys merged into the `[global]` table of the generated
        `continuwuity.toml`, overriding what this profile sets.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (import ../../lib/exposed-service.nix));
      default = null;
      description = ''
        How the reverse proxy serves the homeserver. Clients and other
        homeservers authenticate to Matrix itself, so `auth` belongs off here: a
        sign-in gate in front would leave every client and all federation unable
        to reach the API.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Continuwuity package to run. Defaults to `pkgs.matrix-continuwuity`.";
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "matrix";
      description = "Name of the Continuwuity podman container, and the name the proxy resolves it by.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6167;
      description = "Port the homeserver's client-server API listens on inside the container.";
    };
  };
}
