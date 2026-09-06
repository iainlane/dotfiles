# AgentsView on a machine that runs coding agents.
#
# The agents write session files. AgentsView reads these files and keeps an
# archive of them. It also shows a dashboard of the archive on 127.0.0.1.
#
# Some machines instead push their archive to the shared database, and the
# server's dashboard shows their sessions with the sessions of the other
# machines. Such a machine runs only the push watcher, which ingests the
# session files and pushes them in one process; it has no local dashboard.
#
# The agents also get the AgentsView skill, which tells them how to search
# the archive for past decisions and instructions.
{
  config,
  inputs,
  lib,
}: let
  common = import ./common.nix {
    inherit lib;
    inherit (config.flake) features;
  };

  server = common.serverSettings {
    inherit (config.flake) hosts;
    inherit (config.flake.agentsviewServer) domain;
  };

  # The parts that need the server's address are guarded on this. The assertion
  # below reports a machine that pushes with no server to push to.
  haveServer = server != null;

  configTemplate = "agentsview-config.toml";

  agentsviewFor = system: inputs.llm-agents.packages.${system}.agentsview;

  # The package ships one copy of its skills per harness: the `claude` copy
  # names Claude Code's Task tool, and the `agents` copy is generic. Each file
  # starts with a header containing a hash of its body, and `agentsview skills
  # list` compares that hash with the hash of the skill it generates for the
  # harness in use, so each harness has to be given the copy built for it.
  skillsFor = system: harness: "${agentsviewFor system}/share/agentsview/skills/${harness}";

  # The harness modules, and with them the `dotfiles.ai` and
  # `dotfiles.claudeCode` options, exist only on a host that also composes
  # the `ai` feature.
  skillsModule = {
    lib,
    options,
    system,
    ...
  }: {
    config = lib.optionalAttrs (options ? dotfiles && options.dotfiles ? ai) {
      dotfiles.ai.skills.agentsview = skillsFor system "agents";
      dotfiles.claudeCode.skills.agentsview = skillsFor system "claude";
    };
  };

  # The database answers on 443, the port the web sites already use, and the
  # proxy tells the two apart by the ALPN name in the TLS handshake. That name
  # is present only if the driver opens the connection with TLS, which is what
  # `sslnegotiation=direct` asks for. The default negotiates TLS through a
  # Postgres startup message first, and the proxy would hand that connection to
  # the web server.
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

  # AgentsView reads `config.toml` from its data directory. It carries the
  # auth token on every machine and the database password on a machine that
  # pushes, so sops renders it and keeps it readable only by its owner.
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
      codex_sessions_dirs = [${lib.concatMapStringsSep ", " builtins.toJSON codexSessionsDirs}]
    ''
    + lib.optionalString (url != null) ''

      [pg]
      url = "${url}"
    '';

  # The log of the push. `agentsview pg service logs` reads this path, so that
  # command works against the units declared here.
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

  systemdModule = {
    config,
    lib,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
  in {
    config = lib.mkMerge [
      (lib.mkIf (!cfg.sync.enable) {
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
      (lib.mkIf (cfg.sync.enable && haveServer) {
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
  launchdModule = {
    config,
    lib,
    system,
    ...
  }: let
    cfg = config.dotfiles.agentsview;

    # launchd keeps no record of the output of a job. These files are that
    # record, and they are the first place to look when one of these jobs
    # stops.
    logDir = "${config.home.homeDirectory}/Library/Logs";
  in {
    config = lib.mkMerge [
      (lib.mkIf (!cfg.sync.enable) {
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
      (lib.mkIf (cfg.sync.enable && haveServer) {
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
  homeManager = {
    config,
    hostConfig,
    lib,
    system,
    ...
  }: let
    inherit (hostConfig) name;

    cfg = config.dotfiles.agentsview;

    syncing = cfg.sync.enable;

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
    imports = [./client-options.nix skillsModule];

    config = lib.mkMerge [
      {dotfiles.agentsview.sync.enable = common.pushes hostConfig;}

      {home.packages = [(agentsviewFor system)];}

      {
        assertions = [
          {
            assertion =
              builtins.pathExists (inputs.secrets + "/${common.userSecretsFile name}");
            message = ''
              ${name} keeps an archive of its agent sessions. AgentsView
              generates its auth token and cursor secret at the first start,
              but Nix renders its configuration read-only, so both values
              come from the secrets repository instead.

              This command writes each one that ${name} does not have
              yet:

                just generate-agentsview-secrets ${name}

              It writes them to:

                ${common.userSecretsFile name}
                  ${common.authTokenSecret}: authenticates a caller to the
                    API of the dashboard.
                  ${common.cursorSecret}: signs the cursors of the
                    dashboard.
            '';
          }
        ];
      }

      (lib.mkIf syncing {
        assertions = [
          {
            assertion = haveServer;
            message = ''
              ${name} pushes its agent sessions. No machine has the
              `agentsview-server` feature, so there is no server to push
              to.
            '';
          }
          {
            assertion =
              builtins.pathExists (inputs.secrets + "/${common.passwordFile name}")
              && common.hasCertificate name;
            message = ''
              ${name} pushes its agent sessions, so it also needs a
              database role and a certificate. This command writes each one
              that ${name} does not have yet:

                just generate-agentsview-secrets ${name}

              It writes the certificate to
              `hosts/${name}/agentsview.pem`. Commit that file. It
              writes the rest to the secrets repository:

                ${common.passwordFile name}
                  ${common.passwordSecret}: the password of the database
                    role.
                ${common.userSecretsFile name}
                  ${common.privateKeySecret}: the key of the certificate.
            '';
          }
        ];
      })

      {
        sops = {
          secrets = let
            userSecrets = inputs.secrets + "/${common.userSecretsFile name}";
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
                    hostname = name;
                    password = config.sops.placeholder.${common.passwordSecretName};
                    certificate = common.certificatePath name;
                    key = config.sops.secrets.${common.privateKeySecret}.path;
                  }
                else null;
            };
          };
        };
      }

      (lib.mkIf (syncing && haveServer) {
        sops.secrets = {
          ${common.passwordSecretName} = {
            sopsFile = inputs.secrets + "/${common.passwordFile name}";
            key = common.passwordSecret;
          };

          ${common.privateKeySecret} = {
            sopsFile = inputs.secrets + "/${common.userSecretsFile name}";
            mode = "0400";
          };
        };
      })
    ];
  };

  kernel = {
    linux.homeManager = systemdModule;
    darwin.homeManager = launchdModule;
  };
}
