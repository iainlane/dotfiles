# The machine that holds the shared archive of agent sessions.
#
# A Postgres database receives the pushes. AgentsView shows a read-only
# dashboard of the sessions from all the machines.
#
# The dashboard is web traffic and goes behind the proxy. The database uses
# the same port. The protocol in the handshake tells the two apart.
#
# The host records give the machines that can push: each machine that has the
# `agentsview` profile and is not a work machine. A certificate beside the
# host record identifies each one. This file contains no list of them.
{
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  common = import ../../lib/agentsview.nix {inherit lib;};

  pushers = common.syncingHosts helpers.hosts;

  withoutCertificate =
    lib.attrNames (lib.filterAttrs (hostname: _: !common.hasCertificate hostname) pushers);

  trustedClients =
    map
    (hostname: builtins.readFile (common.certificatePath hostname))
    (lib.attrNames (lib.filterAttrs (hostname: _: common.hasCertificate hostname) pushers));
in {
  flake.profiles.agentsview-server = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.systemManagerModule = args: {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.agentsview-server;

      proxy = config.services.edge-proxy;

      dashboardName = "agentsview";
      databaseName = "agentsview-db";

      # This network holds the database and the dashboard. Thus the dashboard
      # is the only service on this host that reaches the database.
      network = "agentsviewnet";

      dataVolume = "agentsview-db-state";
      dashboardVolume = "agentsview-state";

      databasePort = 5432;

      dataDir = "/data";

      # The location of the database files and of the socket. We choose both,
      # thus this file gives them one time.
      pgData = "/var/lib/postgresql/data";
      pgSocketDir = "/tmp";

      postgresql = pkgs.postgresql_18;

      # Postgres refuses to run as root. At start, it also reads the name of
      # its own id. Thus it gets an id and a name of its own.
      databaseUser = "postgres";
      databaseId = 999;

      databaseNss = pkgs.dockerTools.fakeNss.override {
        extraPasswdLines = [
          "${databaseUser}:x:${toString databaseId}:${toString databaseId}::${pgData}:/bin/sh"
        ];
        extraGroupLines = ["${databaseUser}:x:${toString databaseId}:"];
      };

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      dashboardImage = mkNixImage dashboardName [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview
        # The entrypoint runs in the container. Thus the image must contain
        # the entrypoint and the file that it reads.
        entrypointScript
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      agentsview = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview;

      # The proxy holds the certificate that the machines check. It decrypts
      # the traffic and sends it on. Thus the last part of the path is in the
      # container network and has no TLS. AgentsView asks you to confirm
      # this.
      configFile = (pkgs.formats.toml {}).generate "agentsview.toml" {
        pg.allow_insecure = true;
      };

      # AgentsView reads its configuration from the data directory. It also
      # writes to that file. Thus the first start puts the file in the volume,
      # and subsequent starts keep it.
      entrypointScript = pkgs.writeShellScriptBin "agentsview-entrypoint" ''
        set -eu

        if [ ! -e ${dataDir}/config.toml ]; then
          printf '%s\n' "$(<${configFile})" > ${dataDir}/config.toml
        fi

        exec ${agentsview}/bin/agentsview "$@"
      '';

      # The proxy connects to the database to carry the pushes. If no machine
      # pushes, only the dashboard connects to it.
      reachableFromProxy = trustedClients != [];

      superuser = "postgres";
      superuserSecret = "agentsview_superuser_password";

      databaseImage = mkNixImage databaseName [
        postgresql
        databaseInit
        databaseNss
        pkgs.dockerTools.binSh
      ];

      # The first start makes the data directory. The script then runs the
      # database in the foreground, thus the unit reports the output of the
      # database.
      #
      # The database trusts local connections. The roles unit uses the socket
      # and needs no password. The machines that push connect over the
      # network and give a password.
      databaseInit = pkgs.writeShellScriptBin "agentsview-db-init" ''
        set -eu

        if [ ! -s ${pgData}/PG_VERSION ]; then
          printf '%s\n' "$POSTGRES_PASSWORD" | ${postgresql}/bin/initdb \
            --pgdata=${pgData} \
            --username=${superuser} \
            --pwfile=/dev/stdin \
            --auth-local=trust \
            --auth-host=scram-sha-256 \
            --encoding=UTF8 \
            --locale=C.UTF-8
        fi

        exec ${postgresql}/bin/postgres \
          -D ${pgData} \
          -c listen_addresses='*' \
          -c port=${toString databasePort} \
          -c unix_socket_directories=${pgSocketDir}
      '';

      # `initdb` makes only the default database of a cluster. The first run
      # of this statement makes the database that holds the sessions.
      databaseSql = pkgs.writeText "agentsview-database.sql" ''
        SELECT 'CREATE DATABASE ' || quote_ident('${cfg.database}')
         WHERE NOT EXISTS (
           SELECT FROM pg_database WHERE datname = '${cfg.database}'
         )\gexec
      '';

      # The database reports that it is healthy before this script runs. Thus
      # a small number of attempts is sufficient. You can run the statements
      # more than one time safely.
      rolesScript = pkgs.writeShellScript "agentsview-db-roles" ''
        set -u

        run() {
          podman exec -i ${databaseName} \
            ${postgresql}/bin/psql -q -v ON_ERROR_STOP=1 \
            -h ${pgSocketDir} -U ${superuser} "$@"
        }

        for _ in $(seq 10); do
          if run -d postgres < ${databaseSql} \
             && run -d ${cfg.database} < ${config.sops.templates."agentsview-roles.sql".path}; then
            exit 0
          fi
          sleep 2
        done

        echo "database did not accept the roles" >&2
        exit 1
      '';

      # One shared role owns everything that the machines write. Thus each
      # machine reads the data of the others, and no grant names a machine.
      group = "agentsview_push";

      # Each start applies these statements. Thus a change to the set of
      # machines takes effect at the next deploy.
      rolesSql =
        ''
          DO $$
          BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${group}') THEN
              CREATE ROLE ${group} NOLOGIN;
            END IF;
          END $$;

          -- AgentsView keeps its tables in a schema of its own. The first
          -- machine that pushes makes that schema. This grant lets it. The
          -- `SET ROLE` below makes the shared role the owner, thus each
          -- machine reads the data of the others.
          GRANT ALL ON DATABASE ${cfg.database} TO ${group};

          -- `initdb` sets this password at the first run. This statement
          -- sets it again at each start, thus a new password takes effect
          -- and the cluster stays.
          ALTER ROLE ${superuser} PASSWORD '${config.sops.placeholder.${superuserSecret}}';

          -- A machine that leaves the list keeps its rows and loses access.
          DO $$
          DECLARE
            wanted text[] := ARRAY[${lib.concatMapStringsSep ", " (h: "'${common.role h}'") (lib.attrNames pushers)}];
            member record;
          BEGIN
            FOR member IN
              SELECT m.rolname
                FROM pg_auth_members am
                JOIN pg_roles g ON g.oid = am.roleid
                JOIN pg_roles m ON m.oid = am.member
               WHERE g.rolname = '${group}'
                 AND NOT (m.rolname = ANY (wanted))
            LOOP
              EXECUTE format('ALTER ROLE %I NOLOGIN', member.rolname);
            END LOOP;
          END $$;

        ''
        + lib.concatMapStrings (hostname: let
          name = common.role hostname;
        in ''
          DO $$
          BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}') THEN
              CREATE ROLE "${name}";
            END IF;
          END $$;

          ALTER ROLE "${name}" LOGIN PASSWORD '${config.sops.placeholder.${common.passwordSecretFor hostname}}';
          GRANT ${group} TO "${name}";
          -- The shared role owns everything that this machine makes, thus
          -- the other machines read it.
          ALTER ROLE "${name}" SET ROLE ${group};

        '') (lib.attrNames pushers);

      databaseContainer = {
        autoStart = true;

        containerConfig = {
          image = config.virtualisation.quadlet.images.${databaseName}.ref;

          networks =
            ["${network}.network"]
            ++ lib.optional reachableFromProxy "${proxy.serviceNetwork databaseName}.network";

          # The container uses the host ids. It runs as its own user and has
          # no capabilities. An escape from the container gets an id that owns
          # the database files and nothing more.
          #
          # In a user namespace on this host, connections to Postgres 18 stop
          # at `authentication` and stay there. Thus the container uses host
          # ids. The cause is still unknown.
          user = databaseUser;
          dropCapabilities = ["ALL"];

          entrypoint = "${databaseInit}/bin/agentsview-db-init";

          # `U` tells podman to give the contents to the user of the
          # container. That id is the same at each start, thus podman does
          # this work one time.
          volumes = ["${dataVolume}.volume:${pgData}:U"];

          # `notify` keeps the unit in `activating` until this check passes.
          # Thus the units that come after it start against a database that
          # listens.
          #
          # The check uses the socket, thus the database answers for itself.
          # Each check holds a connection while it waits. The interval is long
          # and keeps the other connections free.
          healthCmd = "${postgresql}/bin/pg_isready -h ${pgSocketDir} -p ${toString databasePort} -U ${superuser}";
          healthInterval = "30s";
          healthRetries = 4;
          healthStartPeriod = "60s";
          notify = "healthy";

          environmentFiles = [config.sops.templates."agentsview-db.env".path];

          # A shutdown writes a checkpoint first. Podman allows ten seconds
          # by default. After that it kills the database, and the next start
          # reads the log back. That time increases with the size of the
          # archive.
          stopTimeout = 120;

          noNewPrivileges = true;
        };

        unitConfig = {
          Description = "AgentsView session database";
          After = ["network-online.target" "sops-install-secrets.service"];
          Wants = ["network-online.target" "sops-install-secrets.service"];
        };
      };

      dashboardContainer = {
        autoStart = true;

        containerConfig = {
          image = config.virtualisation.quadlet.images.${dashboardName}.ref;

          userns = "auto";

          networks = ["${network}.network"];

          entrypoint = "${entrypointScript}/bin/agentsview-entrypoint";

          # This is a flag. A non-loopback address in the configuration file
          # makes AgentsView ask for a token of its own. The proxy in front
          # decides who gets access.
          exec = lib.concatStringsSep " " [
            "pg"
            "serve"
            "--host"
            "0.0.0.0"
            "--port"
            (toString cfg.port)
            "--no-browser"
            # The request comes from the proxy and does not carry the name
            # that the browser used. This flag gives AgentsView that name,
            # and it checks each request against it.
            "--public-url"
            "https://${cfg.expose.domain}"
          ];

          volumes = ["${dashboardVolume}.volume:${dataDir}"];

          environments = {
            AGENTSVIEW_DATA_DIR = dataDir;
          };

          environmentFiles = [config.sops.templates."agentsview.env".path];

          dropCapabilities = ["ALL"];
          noNewPrivileges = true;
        };

        unitConfig = {
          Description = "AgentsView dashboard";
          # The dashboard reads all of its data from the database. Thus it
          # waits for the database and stops with it.
          Requires = ["${databaseName}.service"];
          After = ["${databaseName}.service" "sops-install-secrets.service"];
          Wants = ["sops-install-secrets.service"];
        };
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.agentsview-server = args;}

        (lib.mkIf cfg.enable {
          assertions = [
            {
              assertion = withoutCertificate == [];
              message = ''
                These machines push their agent sessions and have no
                certificate, thus the database refuses them:
                ${lib.concatStringsSep ", " withoutCertificate}. Make a
                certificate for each machine with these commands:
                ${lib.concatMapStrings common.generateCertificate withoutCertificate}
              '';
            }
            {
              assertion = proxy.enable;
              message = ''
                services.agentsview-server needs a proxy on this host. The
                proxy holds the certificate that the machines check, and it
                serves the dashboard.
              '';
            }
          ];

          # The user of the container is a host user, and it owns the
          # database files on the volume. `systemd-sysusers` gives out system
          # ids from 999 down. This entry keeps that id and gives the files a
          # name on the host. No process runs as this user.
          environment.etc."sysusers.d/${databaseName}.conf".text = ''
            u ${databaseName} ${toString databaseId} "AgentsView database" /nonexistent /usr/sbin/nologin
          '';

          systemd.services."${databaseName}-user" = {
            description = "Claim the id the AgentsView database runs as";
            wantedBy = ["system-manager.target"];
            before = ["${databaseName}.service"];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${pkgs.systemd}/bin/systemd-sysusers";
            };
          };

          # The database uses the same port as the web. The protocol tells
          # the two apart. Only the machines with a certificate in this list
          # get through. The stream starts when there is one such machine.
          services.edge-proxy.streams = lib.mkIf reachableFromProxy {
            ${databaseName} = {
              inherit (cfg) domain;
              alpn = "postgresql";
              port = databasePort;
              inherit trustedClients;
            };
          };

          sops = {
            secrets =
              {
                ${superuserSecret}.sopsFile = inputs.secrets + "/${cfg.secretsFile}";
              }
              # The password of each machine that pushes. The roles unit
              # applies the passwords that the secrets repository holds.
              // lib.mapAttrs' (hostname: _:
                lib.nameValuePair (common.passwordSecretFor hostname) {
                  sopsFile = inputs.secrets + "/${common.passwordFile hostname}";
                  key = common.passwordSecret;
                })
              pushers;

            templates = {
              "agentsview-db.env".content = ''
                POSTGRES_PASSWORD=${config.sops.placeholder.${superuserSecret}}
              '';

              "agentsview.env".content = ''
                AGENTSVIEW_PG_URL=postgres://${superuser}:${config.sops.placeholder.${superuserSecret}}@${databaseName}:${toString databasePort}/${cfg.database}?sslmode=disable
              '';

              "agentsview-roles.sql".content = rolesSql;
            };
          };

          systemd.services.agentsview-db-roles = {
            description = "Bring the AgentsView database roles into line";
            requires = ["${databaseName}.service" "sops-install-secrets.service"];
            after = ["${databaseName}.service" "sops-install-secrets.service"];
            wantedBy = ["system-manager.target"];
            path = [config.virtualisation.podman.package];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = rolesScript;
            };
          };

          virtualisation.quadlet = {
            networks.${network} = {};

            volumes = {
              ${dataVolume} = {};
              ${dashboardVolume} = {};
            };

            images = {
              ${dashboardName}.imageConfig = {
                image = "docker-archive:${dashboardImage}";
                tag = "localhost/${dashboardName}:${dashboardImage.imageTag}";
              };

              ${databaseName}.imageConfig = {
                image = "docker-archive:${databaseImage}";
                tag = "localhost/${databaseName}:${databaseImage.imageTag}";
              };
            };

            containers = {
              ${databaseName} = databaseContainer;

              ${dashboardName} =
                proxy.exposePodman dashboardName dashboardContainer
                (cfg.expose // {inherit (cfg) port;});
            };
          };
        })
      ];
    };
  };
}
