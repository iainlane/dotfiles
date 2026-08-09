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

      # AgentsView keeps the vectors for its semantic search in the database.
      # It runs `CREATE EXTENSION vector` at each push, thus pgvector comes
      # with Postgres.
      postgresql = pkgs.postgresql_18.withPackages (p: [p.pgvector]);

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

      agentsview = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview;

      dashboardImage = mkNixImage dashboardName [
        agentsview
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      configPath = "${dataDir}/config.toml";
      configTemplate = "agentsview-config.toml";

      # AgentsView reads this file from its data directory. sops renders it,
      # thus the password stays out of the store.
      #
      # AgentsView makes an auth token and a cursor secret for itself at the
      # first start and writes both into this file. The file is read-only,
      # thus both values come from the secrets repository.
      #
      # The proxy holds the certificate that the machines check. It decrypts
      # the traffic and sends it on. Thus the last part of the path is in the
      # container network and has no TLS. AgentsView asks you to confirm this.
      configContent = ''
        auth_token = "${config.sops.placeholder.${common.authTokenSecret}}"
        cursor_secret = "${config.sops.placeholder.${common.cursorSecret}}"
        disable_update_check = true

        [pg]
        url = "postgres://${dashboardRole}:${config.sops.placeholder.${dashboardSecret}}@${databaseName}:${toString databasePort}/${cfg.database}?sslmode=disable"
        allow_insecure = true
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

      # Who can connect, and how. `initdb` writes rules for the loopback
      # addresses only. The dashboard and the proxy arrive from a podman
      # network, thus this file gives a rule for that range.
      #
      # The roles unit uses the socket, and the database trusts it. Everything
      # else arrives over the network and gives a password.
      hbaFile = pkgs.writeText "pg_hba.conf" ''
        # TYPE  DATABASE  USER  ADDRESS         METHOD
        local   all       all                   trust
        host    all       all   127.0.0.1/32    scram-sha-256
        host    all       all   ::1/128         scram-sha-256
        host    all       all   ${containerRange}  scram-sha-256
      '';

      # Podman gives the networks of this host their addresses from this
      # range.
      containerRange = "10.89.0.0/16";

      # The first start makes the data directory. The script then runs the
      # database in the foreground, thus the unit reports the output of the
      # database.
      databaseInit = pkgs.writeShellScriptBin "agentsview-db-init" ''
        set -eu

        if [ ! -s ${pgData}/PG_VERSION ]; then
          printf '%s\n' "$POSTGRES_PASSWORD" | ${postgresql}/bin/initdb \
            --pgdata=${pgData} \
            --username=${superuser} \
            --pwfile=/dev/stdin \
            --encoding=UTF8 \
            --locale=C.UTF-8
        fi

        exec ${postgresql}/bin/postgres \
          -D ${pgData} \
          -c hba_file=${hbaFile} \
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

      rolesUnit = "${databaseName}-roles";

      # The dashboard connects as a member of the shared role, like the
      # machines do. The superuser makes the roles and does nothing else.
      dashboardRole = "agentsview_dashboard";
      dashboardSecret = "agentsview_dashboard_password";

      # Everything that connects over the network: one role for each machine
      # that pushes, and one for the dashboard.
      clients =
        lib.mapAttrsToList (hostname: _: {
          name = common.role hostname;
          password = config.sops.placeholder.${common.passwordSecretFor hostname};
        })
        pushers
        ++ [
          {
            name = dashboardRole;
            password = config.sops.placeholder.${dashboardSecret};
          }
        ];

      loginRole = client: ''
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${client.name}') THEN
            CREATE ROLE "${client.name}";
          END IF;
        END $$;

        ALTER ROLE "${client.name}" LOGIN PASSWORD '${client.password}';
        GRANT ${group} TO "${client.name}";
        -- The shared role owns everything that this client makes, thus the
        -- other clients read it.
        ALTER ROLE "${client.name}" SET ROLE ${group};

      '';

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

          GRANT ALL ON DATABASE ${cfg.database} TO ${group};

          -- AgentsView holds the vectors of its semantic search in this
          -- extension and asks for it at each push. Only a superuser can
          -- create it, thus it happens here.
          CREATE EXTENSION IF NOT EXISTS vector;

          -- `initdb` sets this password at the first run. This statement
          -- sets it again at each start, thus a new password takes effect
          -- and the cluster stays.
          ALTER ROLE ${superuser} PASSWORD '${config.sops.placeholder.${superuserSecret}}';

          -- A machine that leaves the list keeps its rows and loses access.
          DO $$
          DECLARE
            wanted text[] := ARRAY[${lib.concatMapStringsSep ", " (c: "'${c.name}'") clients}];
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
        + lib.concatMapStrings loginRole clients;

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

          entrypoint = "${agentsview}/bin/agentsview";

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

          # `idmap` maps the ids of the volume into the namespace of the
          # container. `userns=auto` takes a different range at each start.
          # The mapping changes with it, and the owner on disk stays the
          # same.
          volumes = [
            "${dashboardVolume}.volume:${dataDir}:idmap"
            "${config.sops.templates.${configTemplate}.path}:${configPath}:ro,idmap"
          ];

          environments = {
            AGENTSVIEW_DATA_DIR = dataDir;
          };

          dropCapabilities = ["ALL"];
          noNewPrivileges = true;
        };

        unitConfig = {
          Description = "AgentsView dashboard";
          # The dashboard reads all of its data from the database. Thus it
          # waits for the database and stops with it.
          #
          # It also waits for the roles step, which makes the role that it
          # connects as.
          Requires = ["${databaseName}.service" "${rolesUnit}.service"];
          After = [
            "${databaseName}.service"
            "${rolesUnit}.service"
            "sops-install-secrets.service"
          ];
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
                ${lib.concatStringsSep ", " withoutCertificate}.

                Run this command for each of them:
                ${lib.concatMapStrings (hostname: "\n  just generate-agentsview-secrets ${hostname}") withoutCertificate}
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
                ${dashboardSecret}.sopsFile = inputs.secrets + "/${cfg.secretsFile}";
                ${common.authTokenSecret}.sopsFile = inputs.secrets + "/${cfg.secretsFile}";
                ${common.cursorSecret}.sopsFile = inputs.secrets + "/${cfg.secretsFile}";
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

              ${configTemplate}.content = configContent;

              "agentsview-roles.sql".content = rolesSql;
            };
          };

          systemd.services.${rolesUnit} = {
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
