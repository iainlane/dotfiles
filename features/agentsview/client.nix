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
# On a host with `ai`, the agents also get the AgentsView skill from the
# `skills` child.
{
  config,
  featureResolver,
  inputs,
  lib,
  topology,
}: let
  common = import ./common.nix {inherit lib;};
  inherit (topology) server;
  haveServer = server != null;

  configTemplate = "agentsview-config.toml";

  # AgentsView reads `config.toml` from its data directory. It contains the
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
    disabledAgents,
    url,
    vector,
    vectorBackend,
  }:
    common.toTOML ({
        auth_token = authToken;
        cursor_secret = cursorSecret;
        disable_update_check = true;
        codex_sessions_dirs = codexSessionsDirs;
        disabled_agents = disabledAgents;
      }
      // lib.optionalAttrs (url != null) {pg = {inherit url;};}
      // lib.optionalAttrs vector (common.vectorConfig vectorBackend));

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

  # Home Manager restarts a systemd service only when its unit file changes,
  # while these settings live in a sops template outside the unit. Folding a
  # hash of the template into an unknown unit key makes a settings change alter
  # the unit. systemd ignores the key after Home Manager detects the change.
  #
  # The hash covers the template with its placeholders, not the rendered
  # secrets, so rotating a secret's value still needs a manual restart.
  systemdRestartTrigger = config:
    builtins.hashString "sha256" config.sops.templates.${configTemplate}.content;

  systemdModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;
  in {
    config = lib.mkMerge [
      (lib.mkIf (!cfg.sync.enable) {
        systemd.user.services.agentsview = {
          Unit = {
            Description = "Agent session archive and dashboard";
            X-Restart-Triggers = [(systemdRestartTrigger config)];
          };

          Service = {
            ExecStart = "${agentsview}/bin/agentsview serve --no-browser --port ${toString cfg.port}";
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
            X-Restart-Triggers = [(systemdRestartTrigger config)];
          };

          Service = {
            # This command updates the local archive and pushes the changes.
            # It then stays active and repeats the work after each new
            # session.
            ExecStart = "${agentsview}/bin/agentsview pg push --watch";
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
    pkgs,
    ...
  }: let
    cfg = config.dotfiles.agentsview;
    inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;
    agentName =
      if cfg.sync.enable
      then "agentsview-push"
      else "agentsview";

    # launchd keeps no record of the output of a job. These files are that
    # record, and they are the first place to look when one of these jobs
    # stops.
    logDir = "${config.home.homeDirectory}/Library/Logs";
    reloadLog = "${logDir}/agentsview-config-reload.log";
    reloadScript = pkgs.writeShellScript "agentsview-config-reload" ''
      exec /bin/launchctl kickstart -k \
        "gui/$UID/org.nix-community.home.${agentName}"
    '';
  in {
    config = lib.mkMerge [
      (lib.mkIf (!cfg.sync.enable) {
        launchd.agents.agentsview = {
          enable = true;
          config = {
            ProgramArguments = [
              "${agentsview}/bin/agentsview"
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
      (lib.mkIf (cfg.sync.enable && haveServer) {
        launchd.agents.agentsview-push = {
          enable = true;
          config = {
            ProgramArguments = [
              "${agentsview}/bin/agentsview"
              "pg"
              "push"
              "--watch"
            ];
            EnvironmentVariables = pushEnvironment cfg;
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = pushLog cfg;
            StandardErrorPath = pushLog cfg;
          };
        };
      })

      {
        launchd.agents.agentsview-config-reload = {
          enable = true;
          config = {
            Program = reloadScript;
            WatchPaths = [config.sops.templates.${configTemplate}.path];
            ProcessType = "Background";
            StandardOutPath = reloadLog;
            StandardErrorPath = reloadLog;
          };
        };
      }
    ];
  };
in {
  inventory = {
    hostConfig,
    lib,
    ...
  }: {
    agentsview.archive = {
      enable = true;
      publish = lib.mkDefault true;
      secretsFile = lib.mkDefault "${hostConfig.name}/user-agentsview.yaml";
    };
  };
  checks = [./agentsview-secrets-check.nix ./topology-check.nix];
  apps = import ./provisioner.nix {inherit topology;};
  includes =
    [
      (featureResolver.when config.dotfiles.features.ai [
        config.dotfiles.features.agentsview.skills
      ])
      (featureResolver.when config.dotfiles.features.inference.acceleration [
        config.dotfiles.features.agentsview.embeddings.local
      ])
    ]
    ++ [
      (featureResolver.when featureResolver.isLinux [{homeManager = systemdModule;}])
      (featureResolver.when featureResolver.isDarwin [{homeManager = launchdModule;}])
    ];

  homeManager = {
    config,
    hostConfig,
    lib,
    pkgs,
    ...
  }: let
    inherit (hostConfig) name;
    inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;

    cfg = config.dotfiles.agentsview;
    inventory = topology.hosts.${name};
    identity = common.publisher inputs topology.publishers.${name};
    passwordSecretName = "agentsview_password";

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
    imports = [./client-options.nix];

    config = lib.mkMerge [
      {
        dotfiles.agentsview.sync.enable = inventory.archive.publish;
        dotfiles.agentsview.vector = inventory.embeddings != null;
      }

      {home.packages = [agentsview];}

      {
        assertions = [
          {
            assertion =
              builtins.pathExists (inputs.secrets + "/${inventory.archive.secretsFile}");
            message = ''
              ${name} keeps an archive of its agent sessions. AgentsView
              generates its auth token and cursor secret at the first start,
              but Nix renders its configuration read-only, so both values
              come from the secrets repository instead.

              This command writes each one that ${name} does not have
              yet:

                just generate-agentsview-secrets ${name}

              It writes them to:

                ${inventory.archive.secretsFile}
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
              builtins.pathExists (inputs.secrets + "/${identity.passwordFile}")
              && identity.hasCertificate;
            message = ''
              ${name} pushes its agent sessions, so it also needs a
              database role and a certificate. This command writes each one
              that ${name} does not have yet:

                just generate-agentsview-secrets ${name}

              It writes the certificate to
              `hosts/${name}/agentsview.pem`. Commit that file. It
              writes the rest to the secrets repository:

                ${identity.passwordFile}
                  ${common.passwordSecret}: the password of the database
                    role.
                ${inventory.archive.secretsFile}
                  ${common.privateKeySecret}: the key of the certificate.
            '';
          }
        ];
      })

      {
        sops = {
          secrets = let
            userSecrets = inputs.secrets + "/${inventory.archive.secretsFile}";
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
              inherit (cfg) disabledAgents vector;
              vectorBackend =
                if inventory.embeddings == "local"
                then "local"
                else "openrouter";

              authToken = config.sops.placeholder.${common.authTokenSecret};
              cursorSecret = config.sops.placeholder.${common.cursorSecret};

              url =
                if syncing && haveServer
                then
                  common.dsn {
                    inherit server;
                    inherit (identity) machine;
                    password = config.sops.placeholder.${passwordSecretName};
                    certificate = identity.certificatePath;
                    key = config.sops.secrets.${common.privateKeySecret}.path;
                  }
                else null;
            };
          };
        };
      }

      (lib.mkIf (syncing && haveServer) {
        sops.secrets = {
          ${passwordSecretName} = {
            sopsFile = inputs.secrets + "/${identity.passwordFile}";
            key = common.passwordSecret;
          };

          ${common.privateKeySecret} = {
            sopsFile = inputs.secrets + "/${inventory.archive.secretsFile}";
            mode = "0400";
          };
        };
      })
    ];
  };
}
