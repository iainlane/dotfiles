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

  environmentFile = "agentsview-pg.env";

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

  # launchd reads the environment of a job from its own configuration only.
  # Thus both platforms use this script, which reads the address at start.
  pushScript = {
    pkgs,
    agentsview,
    envPath,
    interval,
  }:
    pkgs.writeShellScript "agentsview-push" ''
      set -eu
      set -a
      . ${envPath}
      set +a
      exec ${agentsview}/bin/agentsview pg push --watch --interval ${interval}
    '';
  systemdModule = _: {
    config,
    lib,
    pkgs,
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
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = ["default.target"];
        };
      })

      (lib.mkIf (cfg.enable && cfg.sync.enable && haveServer) {
        systemd.user.services.agentsview-push = {
          Unit = {
            Description = "Push agent sessions to the shared archive";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };

          Service = {
            # This command updates the local archive and pushes the changes.
            # It then stays active and repeats the work after each new
            # session.
            ExecStart = "${pushScript {
              inherit pkgs;
              agentsview = agentsviewFor system;
              envPath = config.sops.templates.${environmentFile}.path;
              inherit (cfg.sync) interval;
            }}";
            Restart = "on-failure";
            RestartSec = 30;
          };

          Install.WantedBy = ["default.target"];
        };
      })
    ];
  };
  launchdModule = _: {
    config,
    lib,
    pkgs,
    system,
    ...
  }: let
    cfg = config.programs.agentsview;
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
            RunAtLoad = true;
            KeepAlive = true;
          };
        };
      })

      (lib.mkIf (cfg.enable && cfg.sync.enable && haveServer) {
        launchd.agents.agentsview-push = {
          enable = true;
          config = {
            ProgramArguments = [
              "${pushScript {
                inherit pkgs;
                agentsview = agentsviewFor system;
                envPath = config.sops.templates.${environmentFile}.path;
                inherit (cfg.sync) interval;
              }}"
            ];
            RunAtLoad = true;
            KeepAlive = true;
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
              assertion = builtins.pathExists (inputs.secrets + "/${common.passwordFile hostname}");
              message = ''
                ${hostname} pushes its agent sessions, thus it needs a
                database role of its own. Add its password to the secrets
                repository as `${common.passwordFile hostname}` under
                `${common.passwordSecret}`.
              '';
            }
            {
              assertion = common.hasCertificate hostname;
              message = ''
                ${hostname} pushes its agent sessions, thus it needs a
                certificate. The proxy uses the certificate to identify the
                machine. Make one with this command:

                ${common.generateCertificate hostname}
                Commit the certificate. Put the key in the secrets repository
                as `${common.privateKeyFile hostname}` under
                `${common.privateKeySecret}`.
              '';
            }
          ];
        })

        (lib.mkIf (syncing && haveServer) {
          sops = {
            secrets = {
              ${common.passwordSecret}.sopsFile =
                inputs.secrets + "/${common.passwordFile hostname}";

              ${common.privateKeySecret} = {
                sopsFile = inputs.secrets + "/${common.privateKeyFile hostname}";
                mode = "0400";
              };
            };

            # The password is the only secret part of the address. The
            # other parts are in plain text here. sops makes the file that
            # holds the result unreadable.
            templates.${environmentFile}.content = ''
              AGENTSVIEW_PG_URL=${dsn {
                inherit hostname;
                password = config.sops.placeholder.${common.passwordSecret};
                certificate = common.certificatePath hostname;
                key = config.sops.secrets.${common.privateKeySecret}.path;
              }}
            '';
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
