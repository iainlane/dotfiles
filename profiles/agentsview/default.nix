# AgentsView on a machine that runs coding agents.
#
# The agents write session files. AgentsView reads these files and keeps an
# archive of them. It also shows a dashboard of the archive on 127.0.0.1.
#
# Some machines also push their archive to the shared database. The server
# then shows their sessions with the sessions of the other machines.
#
# The dashboard and the push run at the same time. The push finds the
# dashboard and sends its work through it.
{
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  common = import ../../lib/agentsview.nix {inherit lib;};

  server = common.serverSettings helpers.hosts;

  # The parts that need an address wait until there is one. The assertion
  # below then reports a machine that pushes to no server.
  haveServer = server != null;

  configTemplate = "agentsview-config.toml";

  agentsviewFor = system: inputs.llm-agents.packages.${system}.agentsview;

  # The database uses the same port as the web. The protocol in the handshake
  # tells the two apart. The driver negotiates TLS this way when you ask for
  # `direct`.
  dsn = {
    hostname,
    password,
    certificate,
    key,
  }:
    "postgres://${common.role hostname}:${password}@${server.domain}:443/${server.database}"
    + "?sslmode=verify-full"
    + "&sslnegotiation=direct"
    # The proxy has a public certificate. The trust store of the machine
    # already knows the issuer.
    + "&sslrootcert=system"
    + "&sslcert=${certificate}"
    + "&sslkey=${key}";

  # AgentsView reads `config.toml` from its data directory. The file holds the
  # address of the database, thus sops renders it and keeps it readable by its
  # owner alone.
  configContent = {
    authToken,
    cursorSecret,
    url,
  }: ''
    auth_token = "${authToken}"
    cursor_secret = "${cursorSecret}"
    disable_update_check = true

    [pg]
    url = "${url}"
  '';

  # The log of the push. `agentsview pg service logs` reads this path, thus
  # that command works beside the units here.
  pushLog = cfg: "${cfg.dataDir}/pg-watch.log";

  systemdModule = _: {
    config,
    lib,
    system,
    ...
  }: let
    cfg = config.programs.agentsview;
  in {
    config = lib.mkMerge [
      (lib.mkIf cfg.enable {
        systemd.user.services.agentsview = {
          Unit.Description = "Agent session archive and dashboard";

          Service = {
            ExecStart = "${agentsviewFor system}/bin/agentsview serve --no-browser --port ${toString cfg.port}";
            Environment = ["AGENTSVIEW_DATA_DIR=${cfg.dataDir}"];
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = ["default.target"];
        };
      })

      # A copy of the unit that `agentsview pg service install` writes.
      (lib.mkIf (cfg.enable && cfg.sync.enable && haveServer) {
        systemd.user.services.agentsview-push = {
          Unit = {
            Description = "agentsview PostgreSQL auto-push";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };

          Service = {
            # This command updates the local archive and pushes the changes.
            # It then stays active and repeats the work after each new
            # session.
            ExecStart = "${agentsviewFor system}/bin/agentsview pg push --watch";
            Environment = ["AGENTSVIEW_DATA_DIR=${cfg.dataDir}"];
            StandardOutput = "append:${pushLog cfg}";
            StandardError = "append:${pushLog cfg}";
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = ["default.target"];
        };
      })
    ];
  };
  launchdModule = _: {
    config,
    lib,
    system,
    ...
  }: let
    cfg = config.programs.agentsview;

    # launchd keeps no record of the output of a job. These files are that
    # record, and they are the first place to look when an agent stops.
    logDir = "${config.home.homeDirectory}/Library/Logs";
  in {
    config = lib.mkMerge [
      (lib.mkIf cfg.enable {
        launchd.agents.agentsview = {
          enable = true;
          config = {
            ProgramArguments = [
              "${agentsviewFor system}/bin/agentsview"
              "serve"
              "--no-browser"
              "--port"
              (toString cfg.port)
            ];
            EnvironmentVariables.AGENTSVIEW_DATA_DIR = cfg.dataDir;
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "${logDir}/agentsview.log";
            StandardErrorPath = "${logDir}/agentsview.log";
          };
        };
      })

      # A copy of the job that `agentsview pg service install` writes.
      (lib.mkIf (cfg.enable && cfg.sync.enable && haveServer) {
        launchd.agents.agentsview-push = {
          enable = true;
          config = {
            ProgramArguments = [
              "${agentsviewFor system}/bin/agentsview"
              "pg"
              "push"
              "--watch"
            ];
            EnvironmentVariables.AGENTSVIEW_DATA_DIR = cfg.dataDir;
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = pushLog cfg;
            StandardErrorPath = pushLog cfg;
          };
        };
      })
    ];
  };
in {
  flake.profiles.agentsview = {
    homeManagerModule = args: {
      config,
      hostConfig,
      hostname,
      lib,
      system,
      ...
    }: let
      cfg = config.programs.agentsview;

      syncing = cfg.enable && cfg.sync.enable;
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {programs.agentsview = args;}

        {programs.agentsview.sync.enable = common.pushes hostConfig;}

        (lib.mkIf cfg.enable {
          home.packages = [(agentsviewFor system)];
        })

        (lib.mkIf syncing {
          assertions = [
            {
              assertion = server != null;
              message = ''
                ${hostname} pushes its agent sessions. No machine has the
                `agentsview-server` profile, thus there is no server to push
                to.
              '';
            }
            {
              assertion =
                builtins.pathExists (inputs.secrets + "/${common.passwordFile hostname}")
                && builtins.pathExists (inputs.secrets + "/${common.userSecretsFile hostname}")
                && common.hasCertificate hostname;
              message = ''
                ${hostname} pushes its agent sessions, thus it needs a
                database role, a certificate, and the two values that
                AgentsView makes for itself. This command writes each one that
                ${hostname} does not have yet:

                  just generate-agentsview-secrets ${hostname}

                It writes the certificate to
                `hosts/${hostname}/agentsview.pem`. Commit that file. It
                writes the rest to the secrets repository:

                  ${common.passwordFile hostname}
                    ${common.passwordSecret}: the password of the database
                      role.
                  ${common.userSecretsFile hostname}
                    ${common.privateKeySecret}: the key of the certificate.
                    ${common.authTokenSecret}: authenticates a caller to the
                      API of the dashboard.
                    ${common.cursorSecret}: signs the cursors of the
                      dashboard.
              '';
            }
          ];
        })

        (lib.mkIf (syncing && haveServer) {
          sops = {
            secrets = let
              userSecrets = inputs.secrets + "/${common.userSecretsFile hostname}";
            in {
              ${common.passwordSecret}.sopsFile =
                inputs.secrets + "/${common.passwordFile hostname}";

              ${common.authTokenSecret}.sopsFile = userSecrets;
              ${common.cursorSecret}.sopsFile = userSecrets;

              ${common.privateKeySecret} = {
                sopsFile = userSecrets;
                mode = "0400";
              };
            };

            # The password and the cursor key are the secret parts. The
            # other parts are in plain text here. sops makes the file that
            # holds the result unreadable.
            templates.${configTemplate} = {
              path = "${cfg.dataDir}/config.toml";

              content = configContent {
                authToken = config.sops.placeholder.${common.authTokenSecret};
                cursorSecret = config.sops.placeholder.${common.cursorSecret};
                url = dsn {
                  inherit hostname;
                  password = config.sops.placeholder.${common.passwordSecret};
                  certificate = common.certificatePath hostname;
                  key = config.sops.secrets.${common.privateKeySecret}.path;
                };
              };
            };
          };
        })
      ];
    };

    os = {
      linux.homeManagerModule = systemdModule;
      nixos.homeManagerModule = systemdModule;
      darwin.homeManagerModule = launchdModule;
    };
  };
}
