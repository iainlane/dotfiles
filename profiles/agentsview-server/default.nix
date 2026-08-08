# The machine holding the shared archive of agent sessions.
#
# A Postgres database takes the pushes, and AgentsView serves a read-only
# dashboard over it showing every machine's sessions together. The dashboard is
# ordinary web traffic and goes behind the proxy like anything else; the
# database is reached over the same port, told apart by the protocol asked for
# during the handshake.
#
# Which machines may push is worked out from the host records: every machine
# with the `agentsview` profile that is not a work machine, identified by the
# certificate sitting beside its host record. Nothing here lists them.
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

      # Just these two on it, so the dashboard reaches the database without
      # the database being reachable from anything else on the host.
      network = "agentsviewnet";

      dataVolume = "agentsview-db-state";
      dashboardVolume = "agentsview-state";

      databasePort = 5432;

      # renovate: datasource=docker depName=docker.io/library/postgres versioning=docker
      databaseTag = "18-alpine";

      dataDir = "/data";

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      dashboardImage = mkNixImage dashboardName [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview
        # The entrypoint runs from inside the container, so it and the file it
        # reads have to be in the image.
        entrypointScript
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      agentsview = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview;

      # The proxy holds the certificate the pushing machines check, and hands
      # over what it decrypts, so this last hop runs inside the container
      # network on its own. AgentsView asks to be told that is deliberate.
      configFile = (pkgs.formats.toml {}).generate "agentsview.toml" {
        pg.allow_insecure = true;
      };

      # AgentsView reads its configuration from the data directory and writes
      # back to it, so the file is written into the volume on first start and
      # left alone after that.
      # Only the shell itself is used to put it there: the image holds
      # AgentsView and a shell, and nothing else to copy a file with.
      entrypointScript = pkgs.writeShellScriptBin "agentsview-entrypoint" ''
        set -eu

        if [ ! -e ${dataDir}/config.toml ]; then
          printf '%s\n' "$(<${configFile})" > ${dataDir}/config.toml
        fi

        exec ${agentsview}/bin/agentsview "$@"
      '';

      # The proxy joins the database only to carry the pushes, so with no
      # machine pushing the database is reached by the dashboard alone.
      reachableFromProxy = trustedClients != [];

      superuser = "postgres";
      superuserSecret = "agentsview_superuser_password";

      # The database reports itself healthy before this runs, so a few
      # attempts are enough to cover a blip. The statements are repeatable, so
      # retrying costs nothing.
      rolesScript = pkgs.writeShellScript "agentsview-db-roles" ''
        set -u

        for _ in $(seq 10); do
          if podman exec -i ${databaseName} \
               psql -q -v ON_ERROR_STOP=1 -U ${superuser} -d ${cfg.database} \
               < ${config.sops.templates."agentsview-roles.sql".path}; then
            exit 0
          fi
          sleep 2
        done

        echo "database did not accept the roles" >&2
        exit 1
      '';

      # Every pushing machine owns what it writes through one shared role, so
      # a machine reads what the others pushed without being granted anything
      # against them by name.
      group = "agentsview_push";

      # Brought into line on every start, so adding or removing a machine
      # takes effect on the next deploy.
      rolesSql =
        ''
          DO $$
          BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${group}') THEN
              CREATE ROLE ${group} NOLOGIN;
            END IF;
          END $$;

          -- AgentsView keeps its tables in a schema of its own, which the
          -- first machine to push creates. Granting on the database is what
          -- lets it, and `SET ROLE` below is what makes the shared role the
          -- owner, so every machine can read what the others wrote.
          GRANT ALL ON DATABASE ${cfg.database} TO ${group};

          -- A machine no longer listed keeps its rows and loses its way in.
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
          -- Everything it creates belongs to the shared role, so the next
          -- machine along can read it.
          ALTER ROLE "${name}" SET ROLE ${group};

        '') (lib.attrNames pushers);

      databaseContainer = {
        autoStart = true;

        containerConfig = {
          image = "docker.io/library/postgres:${databaseTag}";

          networks =
            ["${network}.network"]
            ++ lib.optional reachableFromProxy "${proxy.serviceNetwork databaseName}.network";

          # `auto` shifts the image's own files into the namespace as well as
          # mapping the ids. Given a bare uid map the image looks to be owned
          # by nobody from inside, and the entrypoint's drop from root to the
          # postgres user spins instead of completing.
          userns = "auto";

          # Postgres 18 keeps its data under `/var/lib/postgresql/<major>/`
          # and declares the directory above it as the volume, so that whole
          # directory is what gets kept.
          volumes = ["${dataVolume}.volume:/var/lib/postgresql"];

          # On a fresh volume the database runs once to initialise itself
          # before running for real, and that first pass listens on the local
          # socket alone. Asking over TCP therefore answers only once the
          # database is the one that keeps running.
          #
          # `notify` holds the unit in `activating` until this passes, so
          # anything ordered after it starts against a database that is
          # actually listening.
          healthCmd = "pg_isready -h 127.0.0.1 -p ${toString databasePort} -U ${superuser} -d ${cfg.database}";
          healthInterval = "5s";
          healthRetries = 12;
          healthStartPeriod = "60s";
          notify = "healthy";

          environments = {
            POSTGRES_USER = superuser;
            POSTGRES_DB = cfg.database;
          };

          environmentFiles = [config.sops.templates."agentsview-db.env".path];

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

          # `--host` as a flag: set in the file, a non-loopback address makes
          # AgentsView require a token of its own, and the proxy in front is
          # what decides who is served here.
          exec = lib.concatStringsSep " " [
            "pg"
            "serve"
            "--host"
            "0.0.0.0"
            "--port"
            (toString cfg.port)
            # Nothing here can open one, and it would be asked for on every
            # start.
            "--no-browser"
            # The request arrives from the proxy without the name it was asked
            # for, so AgentsView is told it here and checks it against this.
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
          # It reads everything it serves from the database, so it waits for
          # it and goes down with it.
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
                These machines are set to push their agent sessions but have no
                certificate, so the database would turn them away:
                ${lib.concatStringsSep ", " withoutCertificate}. Make one for
                each with:
                ${lib.concatMapStrings common.generateCertificate withoutCertificate}
              '';
            }
            {
              assertion = proxy.enable;
              message = ''
                services.agentsview-server needs a proxy on this host: it is
                what holds the certificate the pushing machines check, and what
                serves the dashboard.
              '';
            }
          ];

          # Reached on the port the web is served on, told apart from it by
          # the protocol. Only the machines whose certificates are listed here
          # get that far, so the database is offered to the network once there
          # is a machine to offer it to.
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
              # Every pushing machine's password, so the roles can be brought
              # into line with whatever the secrets repository now holds.
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

            images.${dashboardName}.imageConfig = {
              image = "docker-archive:${dashboardImage}";
              tag = "localhost/${dashboardName}:${dashboardImage.imageTag}";
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
