# AgentsView on a machine that runs coding agents.
#
# It reads the session files the agents leave behind, keeps its own archive of
# them, and serves a dashboard over that archive on 127.0.0.1. A machine that
# syncs also pushes the archive to the shared database, so its sessions show up
# in the dashboard the server hosts.
#
# Both run at once: the second writer notices the first and goes through it
# rather than opening the archive itself.
#
# The push only ever goes one way. The archive here stays the original, so a
# machine that pushes nothing still holds everything about itself, and holds
# nothing about anyone else either way.
{
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  common = import ../../lib/agentsview.nix {inherit lib;};

  server = common.serverSettings helpers.hosts;

  # Everything needing an address to push to waits until there is one, so the
  # assertion below is what reports a machine set to push with nowhere to push
  # to.
  haveServer = server != null;

  environmentFile = "agentsview-pg.env";

  agentsviewFor = system: inputs.llm-agents.packages.${system}.agentsview;

  # Reached on the port the web is served on, told apart from it by the
  # protocol asked for during the handshake. The driver negotiates TLS that
  # way when asked for `direct`.
  dsn = {
    hostname,
    password,
    certificate,
    key,
  }:
    "postgres://${common.role hostname}:${password}@${server.domain}:443/${server.database}"
    + "?sslmode=verify-full"
    + "&sslnegotiation=direct"
    # The proxy is served under a public certificate, so the machine's trust
    # store already knows who signed it.
    + "&sslrootcert=system"
    + "&sslcert=${certificate}"
    + "&sslkey=${key}";

  # launchd cannot read a job's environment from a file, so both platforms go
  # through this and pick the address up at startup.
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
            # Brings the local archive up to date, pushes what changed, then
            # stays running and does it again whenever a session is written.
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
                ${hostname} is set to push its agent sessions, but no machine
                has the `agentsview-server` profile, so there is nowhere to
                push them to.
              '';
            }
            {
              assertion = builtins.pathExists (inputs.secrets + "/${common.passwordFile hostname}");
              message = ''
                ${hostname} is set to push its agent sessions, so it needs a
                database role of its own. Add its password to the secrets
                repository as `${common.passwordFile hostname}` under
                `${common.passwordSecret}`.
              '';
            }
            {
              assertion = common.hasCertificate hostname;
              message = ''
                ${hostname} is set to push its agent sessions, so it needs a
                certificate to identify itself to the proxy. Make one with:

                ${common.generateCertificate hostname}
                Commit the certificate, and put the key in the secrets
                repository as `${common.privateKeyFile hostname}` under
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

            # The password is the only part of the address worth hiding, so
            # the rest is written out plainly and the rendered file is what
            # stays unreadable.
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
