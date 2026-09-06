# The machine that keeps the shared archive of agent sessions.
#
# A Postgres database receives the pushes, and AgentsView serves a read-only
# dashboard of the sessions from every machine.
#
# The dashboard is web traffic and goes behind the proxy. The database is
# served on the same port, and the ALPN name in the TLS handshake tells the two
# apart.
#
# The machines that may push come from the host records: every host with the
# `agentsview` feature that is not a work machine. A certificate stored beside
# the host record identifies each one, so this file lists no machine itself.
{
  config,
  lib,
}: let
  common = import ./common.nix {
    inherit lib;
    inherit (config.flake) features;
  };

  pushers = common.syncingHosts config.flake.hosts;

  serverDomain = config.flake.agentsviewServer.domain;

  withoutCertificate =
    lib.attrNames (lib.filterAttrs (hostname: _: !common.hasCertificate hostname) pushers);

  trustedClients =
    map
    (hostname: builtins.readFile (common.certificatePath hostname))
    (lib.attrNames (lib.filterAttrs (hostname: _: common.hasCertificate hostname) pushers));
in {
  includes = [config.flake.features.containers config.flake.features.agentsview-server.provides.backup];

  systemManager = {
    config,
    exposePodman,
    hostConfig,
    inputs,
    lib,
    pkgs,
    quadlet,
    serviceNetwork,
    ...
  }: let
    cfg = config.dotfiles.agentsviewServer;

    secretsFile = inputs.secrets + "/${cfg.secretsFile}";

    proxy = config.dotfiles.containers.edgeProxy;

    database = import ./server-database.nix {inherit pkgs;};

    dashboardName = "agentsview";

    # Only the database and the dashboard join this network, so the dashboard
    # is the only service on this host that reaches the database.
    networkName = "agentsviewnet";
    network = config.virtualisation.quadlet.networks.${networkName}.ref;

    dataVolume = "agentsview-db-state";
    dashboardVolume = "agentsview-state";

    dataDir = "/data";

    pgData = "/var/lib/postgresql/data";

    # Postgres refuses to run as root, and at startup it looks up the name of
    # the id it runs as, so it needs both an id and a passwd entry for it.
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

    # AgentsView reads this file from its data directory. sops renders it, so
    # the password stays out of the store.
    #
    # AgentsView would generate an auth token and a cursor secret for itself at
    # first start and write them into this file, but a rendered file is
    # read-only, so both values come from the secrets repository instead.
    #
    # The dashboard connects to the database in plain text over the network the
    # two of them share. The certificate the pushing machines check belongs to
    # the proxy, which terminates TLS and passes the connection on unencrypted.
    # `allow_insecure` confirms to AgentsView that this is deliberate.
    configContent = ''
      auth_token = "${config.sops.placeholder.${common.authTokenSecret}}"
      cursor_secret = "${config.sops.placeholder.${common.cursorSecret}}"
      disable_update_check = true

      [pg]
      url = "postgres://${dashboardRole}:${config.sops.placeholder.${dashboardSecret}}@${database.containerName}:${toString database.port}/${cfg.database}?sslmode=disable"
      allow_insecure = true
    '';

    # The proxy joins the database's network only to pass pushes on. With no
    # machine pushing, the dashboard is the only thing that connects.
    reachableFromProxy = trustedClients != [];

    superuserSecret = "agentsview_superuser_password";

    databaseImage = mkNixImage database.containerName [
      database.package
      databaseInit
      databaseNss
      pkgs.dockerTools.binSh
    ];

    # Who may connect, and how. `initdb` writes rules for the loopback
    # addresses only. The dashboard and the proxy arrive from a podman network,
    # so this file adds a rule for every range podman draws a network from.
    #
    # The roles unit connects over the unix socket, which is trusted without a
    # password. Everything else arrives over the network and has to send one.
    hbaFile = pkgs.writeText "pg_hba.conf" ''
      # TYPE  DATABASE  USER  ADDRESS         METHOD
      local   all       all                   trust
      host    all       all   127.0.0.1/32    scram-sha-256
      host    all       all   ::1/128         scram-sha-256
      ${lib.concatMapStringsSep "\n" (range: "host    all       all   ${range}  scram-sha-256") config.dotfiles.containers.subnetPools}
    '';

    # The first start creates the data directory. The script then execs
    # postgres in the foreground, so the container's main process is the
    # database itself and its output reaches the unit's journal.
    databaseInit = pkgs.writeShellScriptBin "agentsview-db-init" ''
      set -eu

      if [ ! -s ${pgData}/PG_VERSION ]; then
        printf '%s\n' "$POSTGRES_PASSWORD" | ${database.package}/bin/initdb \
          --pgdata=${pgData} \
          --username=${database.superuser} \
          --pwfile=/dev/stdin \
          --encoding=UTF8 \
          --locale=C.UTF-8
      fi

      exec ${database.package}/bin/postgres \
        -D ${pgData} \
        -c hba_file=${hbaFile} \
        -c listen_addresses='*' \
        -c port=${toString database.port} \
        -c unix_socket_directories=${database.socketDir}
    '';

    # `initdb` creates only the cluster's default database. The first run of
    # this statement creates the database the sessions are stored in.
    databaseSql = pkgs.writeText "agentsview-database.sql" ''
      SELECT 'CREATE DATABASE ' || quote_ident('${cfg.database}')
       WHERE NOT EXISTS (
         SELECT FROM pg_database WHERE datname = '${cfg.database}'
       )\gexec
    '';

    # The database has already reported itself healthy before this script
    # runs, so ten attempts two seconds apart cover the rest of its startup.
    # Every creation statement below checks for the object first, and the
    # remaining statements reapply the configured state, so a retry after a
    # partial run changes nothing that already matches.
    rolesScript = pkgs.writeShellScript "agentsview-db-roles" ''
      set -u

      run() {
        podman exec -i ${database.containerName} \
          ${database.package}/bin/psql -q -v ON_ERROR_STOP=1 \
          -h ${database.socketDir} -U ${database.superuser} "$@"
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

    # One shared role owns every object the machines create, so each machine
    # can read what the others wrote and no grant has to name an individual
    # machine.
    group = "agentsview_push";

    rolesUnit = "${database.containerName}-roles";

    # The dashboard connects as a member of the shared role, as the machines
    # do. The superuser is what the health check and the roles unit connect
    # as; the roles unit creates the database, the extension and the roles.
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
      -- Objects this client creates are owned by the shared role, so the
      -- other clients can read them.
      ALTER ROLE "${client.name}" SET ROLE ${group};

    '';

    # These statements run at every start, so a change to the set of machines
    # takes effect on the next deploy.
    rolesSql =
      ''
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${group}') THEN
            CREATE ROLE ${group} NOLOGIN;
          END IF;
        END $$;

        GRANT ALL ON DATABASE ${cfg.database} TO ${group};

        -- Only a superuser can create an extension, and the role a push
        -- connects as is not one, so pgvector is created here.
        CREATE EXTENSION IF NOT EXISTS vector;

        -- `initdb` sets this password on the first run only. Setting it
        -- again at every start means a rotated password takes effect
        -- without recreating the cluster.
        ALTER ROLE ${database.superuser} PASSWORD '${config.sops.placeholder.${superuserSecret}}';

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
        image = config.virtualisation.quadlet.images.${database.containerName}.ref;

        networks =
          [network]
          ++ lib.optional reachableFromProxy "${serviceNetwork database.containerName}.network";

        # A user namespace is not used here: with one, on this host,
        # connections to Postgres 18 hang in `authentication` and never
        # complete. The cause is still unknown.
        user = databaseUser;
        dropCapabilities = ["ALL"];

        entrypoint = "${databaseInit}/bin/agentsview-db-init";

        # The database user has the same host id at every start, so chowning
        # the volume is stable. A container with an auto user namespace needs
        # `idmap` instead, because the ids it maps to change between starts.
        volumes = quadlet.mounts [
          {
            source.quadletVolume = dataVolume;
            target = pgData;
            ownership = "chown";
          }
        ];

        # `notify` keeps the unit in `activating` until this check passes, so
        # the units ordered after it start against a database that is
        # listening.
        #
        # The check goes over the unix socket, so it tests the database rather
        # than the network path to it. Each check occupies a connection while
        # it runs, and the long interval keeps that cost down.
        healthCmd = "${database.package}/bin/pg_isready -h ${database.socketDir} -p ${toString database.port} -U ${database.superuser}";
        healthInterval = "30s";
        healthRetries = 4;
        healthStartPeriod = "60s";
        notify = "healthy";

        environmentFiles = [config.sops.templates."agentsview-db.env".path];

        # Postgres writes a checkpoint before it shuts down, and how long that
        # takes grows with the size of the archive. podman allows ten seconds
        # by default, then kills the database, and the next start has to replay
        # the write-ahead log.
        stopTimeout = 120;

        noNewPrivileges = true;
      };

      unitConfig = {
        Description = "AgentsView session database";
        After = ["network-online.target" "sops-install-secrets.service"];
        Wants = ["network-online.target" "sops-install-secrets.service"];
      };

      # Systemd must allow more time than Podman's 120-second stop timeout,
      # or it can kill the container during the database shutdown checkpoint.
      serviceConfig.TimeoutStopSec = 180;
    };

    dashboardContainer = {
      autoStart = true;

      containerConfig = {
        image = config.virtualisation.quadlet.images.${dashboardName}.ref;

        userns = "auto";

        networks = [network];

        entrypoint = "${agentsview}/bin/agentsview";

        # AgentsView requires its own auth token once it binds a non-loopback
        # address. That token comes from the config file above; the proxy in
        # front is what decides who reaches the dashboard.
        exec = lib.concatStringsSep " " [
          "pg"
          "serve"
          "--host"
          "0.0.0.0"
          "--port"
          (toString cfg.port)
          "--no-browser"
          # The request arrives from the proxy without the name the browser
          # used. This flag tells AgentsView that name, which it checks each
          # request against.
          "--public-url"
          "https://${cfg.expose.domain}"
        ];

        volumes = quadlet.mounts [
          {
            source.quadletVolume = dashboardVolume;
            target = dataDir;
            ownership = "idmap";
          }
          {
            source.bind = config.sops.templates.${configTemplate}.path;
            target = configPath;
            ownership = "idmap";
            readOnly = true;
          }
        ];

        environments = {
          AGENTSVIEW_DATA_DIR = dataDir;
        };

        dropCapabilities = ["ALL"];
        noNewPrivileges = true;
      };

      unitConfig = {
        Description = "AgentsView dashboard";
        # The dashboard reads all of its data from the database, so it waits
        # for the database and stops with it. It also waits for the roles unit,
        # which creates the role it connects as.
        Requires = ["${database.containerName}.service" "${rolesUnit}.service"];
        After = [
          "${database.containerName}.service"
          "${rolesUnit}.service"
          "sops-install-secrets.service"
        ];
        Wants = ["sops-install-secrets.service"];
      };
    };
  in {
    imports = [(import ./server-options.nix {inherit common;})];

    config = lib.mkMerge [
      (lib.mkIf (serverDomain != null) {dotfiles.agentsviewServer.domain = serverDomain;})

      {
        assertions = [
          {
            assertion = withoutCertificate == [];
            message = ''
              These machines push their agent sessions and have no
              certificate, so the database refuses them:
              ${lib.concatStringsSep ", " withoutCertificate}.

              Run this command for each of them:
              ${lib.concatMapStrings (hostname: "\n  just generate-agentsview-secrets ${hostname}") withoutCertificate}
            '';
          }
          {
            assertion = builtins.pathExists secretsFile;
            message = ''
              The AgentsView server has no ${cfg.secretsFile} in the secrets
              repository. It needs four keys:

                agentsview_superuser_password
                agentsview_dashboard_password
                ${common.authTokenSecret}
                ${common.cursorSecret}

              Write them with:

                just generate-agentsview-secrets ${hostConfig.name}
            '';
          }
          {
            assertion = proxy.enable;
            message = ''
              dotfiles.agentsviewServer needs a proxy on this host, which is
              what sets dotfiles.containers.edgeProxy.enable. The proxy
              presents the certificate the pushing machines check, and it
              serves the dashboard.
            '';
          }
        ];

        # The container runs with the host's ids, so the database files on the
        # volume are owned by host id 999. `systemd-sysusers` hands out system
        # ids from 999 downwards, so this entry reserves that id and gives the
        # files an owner name on the host.
        #
        # `virtualisation.containers.idRanges` reserves ranges a container maps
        # into a namespace of its own. This container uses the host's ids, so
        # its single id is claimed here instead.
        environment.etc."sysusers.d/${database.containerName}.conf".text = ''
          u ${database.containerName} ${toString databaseId} "AgentsView database" /nonexistent /usr/sbin/nologin
        '';

        systemd.services."${database.containerName}-user" = {
          description = "Claim the id the AgentsView database runs as";
          wantedBy = ["system-manager.target"];
          before = ["${database.containerName}.service"];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.systemd}/bin/systemd-sysusers";
          };
        };

        # The database is served on the same port as the web sites, and the
        # ALPN name tells the two apart. Only machines whose certificate is in
        # this list get through, and the stream is declared only when there is
        # at least one.
        dotfiles.containers.edgeProxy.streams = lib.mkIf reachableFromProxy {
          ${database.containerName} = {
            inherit (cfg) domain;
            alpn = "postgresql";
            inherit (database) port;
            inherit trustedClients;
          };
        };

        sops = {
          secrets =
            {
              ${superuserSecret}.sopsFile = secretsFile;
              ${dashboardSecret}.sopsFile = secretsFile;
              ${common.authTokenSecret}.sopsFile = secretsFile;
              ${common.cursorSecret}.sopsFile = secretsFile;
            }
            # The password of each machine that pushes. The roles unit applies
            # whatever the secrets repository currently has.
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
          requires = ["${database.containerName}.service" "sops-install-secrets.service"];
          after = ["${database.containerName}.service" "sops-install-secrets.service"];
          wantedBy = ["system-manager.target"];
          path = [config.virtualisation.podman.package];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = rolesScript;
          };
        };

        virtualisation.quadlet = {
          networks.${networkName} = {};

          volumes = {
            ${dataVolume} = {};
            ${dashboardVolume} = {};
          };

          images = {
            ${dashboardName}.imageConfig = {
              image = "docker-archive:${dashboardImage}";
              tag = "localhost/${dashboardName}:${dashboardImage.imageTag}";
            };

            ${database.containerName}.imageConfig = {
              image = "docker-archive:${databaseImage}";
              tag = "localhost/${database.containerName}:${databaseImage.imageTag}";
            };
          };

          containers = {
            ${database.containerName} = databaseContainer;

            ${dashboardName} =
              exposePodman dashboardName dashboardContainer
              (cfg.expose // {inherit (cfg) port;});
          };
        };
      }
    ];
  };
}
