# AgentsView on a machine that runs coding agents.
#
# The agents write session files. AgentsView reads these files and keeps an
# archive of them. It also shows a dashboard of the archive on 127.0.0.1.
#
# Some machines instead push their archive to the shared database, and the
# server's dashboard shows their sessions with the sessions of the other
# machines. Such a machine runs only the push watcher, which ingests the
# session files and pushes them in one process; it has no local dashboard.
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

  # AgentsView reads `config.toml` from its data directory. On a machine that
  # pushes, the file holds the address of the database, so sops renders it and
  # keeps it readable only by its owner.
  #
  # AgentsView generates the auth token and the cursor secret itself whenever
  # either is missing from the file, and it refuses to start when it cannot
  # write them. A rendered file is read-only, so this template supplies both.
  configContent = {
    authToken,
    cursorSecret,
    codexSessionsDirs,
    url,
  }:
    ''
      auth_token = "${authToken}"
      cursor_secret = "${cursorSecret}"
      disable_update_check = true
      codex_sessions_dirs = [${lib.concatMapStringsSep ", " (dir: "\"${dir}\"") codexSessionsDirs}]
    ''
    + lib.optionalString (url != null) ''

      [pg]
      url = "${url}"
    '';

  # The log of the push. `agentsview pg service logs` reads this path, thus
  # that command works beside the units here.
  pushLog = cfg: "${cfg.dataDir}/pg-watch.log";

  # The push watcher's environment. With daemon auto-start disabled the
  # watcher ingests the session files and writes the archive itself; without
  # `AGENTSVIEW_NO_DAEMON` it would spawn a dashboard daemon and push through
  # that.
  pushEnvironment = cfg: {
    AGENTSVIEW_DATA_DIR = cfg.dataDir;
    AGENTSVIEW_NO_DAEMON = "1";
  };

  # Activation restarts a service only when its unit file changes, and the
  # settings live in a sops template outside the unit. Folding a hash of the
  # template into the unit makes a settings change alter the unit, so the
  # daemons restart on switch and read the new file. This is what NixOS's
  # `restartTriggers` does for systemd; launchd and systemd both ignore the
  # unknown key.
  #
  # The hash covers the template with its placeholders, not the rendered
  # secrets, so rotating a secret's value still needs a manual restart.
  restartTrigger = config:
    builtins.hashString "sha256" config.sops.templates.${configTemplate}.content;

  systemdModule = _: {
    config,
    lib,
    system,
    ...
  }: let
    cfg = config.programs.agentsview;
  in {
    config = lib.mkMerge [
      (lib.mkIf (cfg.enable && !cfg.sync.enable) {
        systemd.user.services.agentsview = {
          Unit = {
            Description = "Agent session archive and dashboard";
            X-Restart-Triggers = [(restartTrigger config)];
          };

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
            X-Restart-Triggers = [(restartTrigger config)];
          };

          Service = {
            # This command updates the local archive and pushes the changes.
            # It then stays active and repeats the work after each new
            # session.
            ExecStart = "${agentsviewFor system}/bin/agentsview pg push --watch";
            Environment =
              lib.mapAttrsToList (name: value: "${name}=${value}")
              (pushEnvironment cfg);
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
      (lib.mkIf (cfg.enable && !cfg.sync.enable) {
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
            X-Restart-Triggers = restartTrigger config;
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
            EnvironmentVariables = pushEnvironment cfg;
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = pushLog cfg;
            StandardErrorPath = pushLog cfg;
            X-Restart-Triggers = restartTrigger config;
          };
        };
      })
    ];
  };
in {
  options.flake.agentsviewHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.enum ["server" "client" "local"]);
    description = ''
      What each machine with the AgentsView profile does with its archive.
      `just generate-agentsview-secrets` reads this to decide which secrets
      each machine needs.
    '';
  };

  config.flake.agentsviewHosts = common.kinds helpers.hosts;

  config.flake.profiles.agentsview = {
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

      # Codex writes its sessions under `CODEX_HOME`, which the Codex module
      # sets when the home prefers XDG directories. Reading that variable
      # means AgentsView looks where Codex actually writes.
      codexHome =
        config.home.sessionVariables.CODEX_HOME
        or "${config.home.homeDirectory}/.codex";

      # Setting `codex_sessions_dirs` replaces both of the directories
      # AgentsView searches by default, so the archived one is listed here
      # too.
      codexSessionsDirs = [
        "${codexHome}/sessions"
        "${codexHome}/archived_sessions"
      ];
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {programs.agentsview = args;}

        {programs.agentsview.sync.enable = common.pushes hostConfig;}

        (lib.mkIf cfg.enable {
          home.packages = [(agentsviewFor system)];
        })

        (lib.mkIf cfg.enable {
          assertions = [
            {
              assertion =
                builtins.pathExists (inputs.secrets + "/${common.userSecretsFile hostname}");
              message = ''
                ${hostname} keeps an archive of its agent sessions. AgentsView
                generates its auth token and cursor secret at the first start,
                but Nix renders its configuration read-only, so both values
                come from the secrets repository instead.

                This command writes each one that ${hostname} does not have
                yet:

                  just generate-agentsview-secrets ${hostname}

                It writes them to:

                  ${common.userSecretsFile hostname}
                    ${common.authTokenSecret}: authenticates a caller to the
                      API of the dashboard.
                    ${common.cursorSecret}: signs the cursors of the
                      dashboard.
              '';
            }
          ];
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
                && common.hasCertificate hostname;
              message = ''
                ${hostname} pushes its agent sessions, so it also needs a
                database role and a certificate. This command writes each one
                that ${hostname} does not have yet:

                  just generate-agentsview-secrets ${hostname}

                It writes the certificate to
                `hosts/${hostname}/agentsview.pem`. Commit that file. It
                writes the rest to the secrets repository:

                  ${common.passwordFile hostname}
                    ${common.passwordSecret}: the password of the database
                      role.
                  ${common.userSecretsFile hostname}
                    ${common.privateKeySecret}: the key of the certificate.
              '';
            }
          ];
        })

        (lib.mkIf cfg.enable {
          sops = {
            secrets = let
              userSecrets = inputs.secrets + "/${common.userSecretsFile hostname}";
            in {
              ${common.authTokenSecret}.sopsFile = userSecrets;
              ${common.cursorSecret}.sopsFile = userSecrets;
            };

            # The tokens and the database password are secret; the rest of
            # the file is plain text. sops renders the result and makes it
            # unreadable to other users.
            templates.${configTemplate} = {
              path = "${cfg.dataDir}/config.toml";

              content = configContent {
                inherit codexSessionsDirs;

                authToken = config.sops.placeholder.${common.authTokenSecret};
                cursorSecret = config.sops.placeholder.${common.cursorSecret};

                url =
                  if syncing && haveServer
                  then
                    dsn {
                      inherit hostname;
                      password = config.sops.placeholder.${common.passwordSecret};
                      certificate = common.certificatePath hostname;
                      key = config.sops.secrets.${common.privateKeySecret}.path;
                    }
                  else null;
              };
            };
          };
        })

        (lib.mkIf (syncing && haveServer) {
          sops.secrets = {
            ${common.passwordSecret}.sopsFile =
              inputs.secrets + "/${common.passwordFile hostname}";

            ${common.privateKeySecret} = {
              sopsFile = inputs.secrets + "/${common.userSecretsFile hostname}";
              mode = "0400";
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
