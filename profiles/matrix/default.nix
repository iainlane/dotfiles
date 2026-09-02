# A Continuwuity Matrix homeserver, served through the reverse proxy.
#
# The homeserver owns its own accounts and state and knows nothing about what
# talks to it. Clients reach it at its public name, which is also how the agent
# on this host reaches it.
{
  flake.profiles.matrix = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.systemManagerModule = args: {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.continuwuity;
      secretsFile = inputs.secrets + "/${cfg.secretsFile}";

      package =
        if cfg.package != null
        then cfg.package
        else pkgs.matrix-continuwuity;

      databasePath = "/var/lib/continuwuity";
      backupPath = "/var/lib/continuwuity-backup";
      configPath = "/etc/continuwuity.toml";
      adminConfigPath = "/etc/continuwuity-admin.toml";
      stateVolume = "matrix-state";
      backupVolume = "matrix-backup";
      backupUnit = "${cfg.containerName}-backup";

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      r2Backup = import ../../lib/r2-backup.nix;
      uploader = r2Backup.uploader {inherit pkgs;};
      verifier = r2Backup.verifier {inherit pkgs;};
      backupScript = pkgs.writeShellApplication {
        name = "matrix-backup";
        runtimeInputs = [pkgs.coreutils];
        text = builtins.readFile ./backup.sh;
      };

      image = mkNixImage cfg.containerName [
        package
        pkgs.coreutils
        pkgs.curl
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      supportUsers = lib.attrNames (lib.filterAttrs (_: user: user.supportUser) cfg.users);

      wellKnown =
        lib.optionalAttrs (cfg.expose != null) {
          # `server_name` is the identity; the homeserver answers at
          # `expose.domain`. These documents point one at the other. Clients
          # and other homeservers fetch them from the identity domain, which
          # redirects here.
          client = "https://${cfg.expose.domain}";
          server = "${cfg.expose.domain}:443";
        }
        // lib.optionalAttrs (supportUsers != []) {
          support_mxid = "@${lib.head supportUsers}:${cfg.serverName}";
        };

      configFile = (pkgs.formats.toml {}).generate "continuwuity.toml" {
        global =
          {
            server_name = cfg.serverName;
            address = ["0.0.0.0"];
            port = [cfg.port];
            database_path = databasePath;
            allow_federation = true;
            # Token-gated registration: the agent's account is created
            # administratively below, and registration is open to anyone holding
            # the token, so accounts can be made from a Matrix client without the
            # password ever passing through the logs.
            allow_registration = true;
            # The account-creation commands are idempotent: they error once the
            # account exists. Ignoring that keeps the homeserver up on later
            # boots.
            admin_execute_errors_ignore = true;
            trusted_servers = [];
          }
          // lib.optionalAttrs (wellKnown != {}) {well_known = wellKnown;}
          // lib.optionalAttrs cfg.backup.enable {
            database_backup_path = backupPath;
            database_backups_to_keep = cfg.backup.keep;
            # SIGUSR2 runs these, which is how the timer asks for a backup.
            admin_signal_execute = ["server backup-database"];
          }
          // cfg.settings;
      };

      # Admin commands the homeserver runs at startup: always create the agent's
      # account, then any extra accounts, granting admin where asked. Passwords
      # arrive as sops placeholders, substituted when the overlay is rendered.
      adminCommands =
        ["users create_user ${cfg.botUsername} ${config.sops.placeholder.matrix_password}"]
        ++ lib.concatLists (
          lib.mapAttrsToList (
            name: user:
              lib.optional (user.passwordKey != null)
              "users create_user ${name} ${config.sops.placeholder.${user.passwordKey}}"
              ++ lib.optional user.admin "users make-user-admin ${name}"
          )
          cfg.users
        );

      matrixContainer = import ./container.nix {
        inherit adminConfigPath backupPath backupVolume configFile configPath databasePath cfg lib pkgs package stateVolume;
        adminConfigFile = config.sops.templates."continuwuity-admin.toml".path;
        image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;
      };

      expose = cfg.expose != null && config.services.edge-proxy.enable;
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.continuwuity = args;}
        {
          assertions = [
            {
              assertion = lib.length supportUsers <= 1;
              message = ''
                services.continuwuity publishes one support contact, and
                ${lib.concatStringsSep ", " supportUsers} are all marked
                `supportUser`.
              '';
            }
          ];

          sops = lib.mkMerge [
            (lib.mkIf cfg.backup.enable (r2Backup.sopsFragment {
              inherit config;
              secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
              templateName = "matrix-backup.env";
            }))
            {
              secrets =
                {
                  matrix_password.sopsFile = secretsFile;
                  matrix_registration_token.sopsFile = secretsFile;
                }
                // lib.mapAttrs' (
                  _: user: lib.nameValuePair user.passwordKey {sopsFile = secretsFile;}
                )
                (lib.filterAttrs (_: user: user.passwordKey != null) cfg.users);

              # A config overlay carrying the secret-bearing settings. Living in a
              # mode-restricted file keeps the passwords out of the world-readable
              # store and out of process arguments.
              templates."continuwuity-admin.toml" = {
                content = ''
                  [global]
                  registration_token = ${builtins.toJSON config.sops.placeholder.matrix_registration_token}
                  admin_execute = ${builtins.toJSON adminCommands}
                '';
              };
            }
          ];

          systemd = lib.mkIf cfg.backup.enable {
            services.${backupUnit} = {
              description = "Back the Continuwuity database up to Cloudflare R2";
              requires = ["${cfg.containerName}.service" "sops-install-secrets.service"];
              after = ["${cfg.containerName}.service" "sops-install-secrets.service" "network-online.target"];
              wants = ["network-online.target"];
              path = [config.virtualisation.podman.package uploader];
              serviceConfig = r2Backup.withScratchDirectory backupUnit {
                Type = "oneshot";
                EnvironmentFile = config.sops.templates."matrix-backup.env".path;
                Environment = [
                  "MATRIX_CONTAINER=${cfg.containerName}"
                  "MATRIX_BACKUP_VOLUME=${backupVolume}"
                  "MATRIX_BACKUP_TIMEOUT=${toString cfg.backup.timeout}"
                  "BACKUP_NAME=${cfg.containerName}"
                  "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
                  "BACKUP_PREFIX=${cfg.backup.prefix}"
                  "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
                ];
                ExecStart = "${backupScript}/bin/matrix-backup";
              };
            };

            timers.${backupUnit} = {
              description = "Schedule the Continuwuity backup";
              wantedBy = ["timers.target"];
              timerConfig = {
                OnCalendar = cfg.backup.schedule;
                Persistent = true;
                RandomizedDelaySec = "15m";
              };
            };

            services."${backupUnit}-verify" = lib.mkIf cfg.backup.verify.enable {
              description = "Check the Continuwuity R2 backup arrived";
              requires = ["sops-install-secrets.service"];
              after = ["network-online.target" "sops-install-secrets.service"];
              wants = ["network-online.target"];
              serviceConfig = {
                Type = "oneshot";
                EnvironmentFile = config.sops.templates."matrix-backup.env".path;
                Environment = [
                  "BACKUP_NAME=${cfg.containerName}"
                  "BACKUP_PREFIX=${cfg.backup.prefix}"
                  "BACKUP_MAX_AGE_HOURS=${toString cfg.backup.verify.maxAgeHours}"
                  "BACKUP_MIN_SIZE=${toString cfg.backup.verify.minSizeBytes}"
                  "BACKUP_MIN_COUNT=${toString cfg.backup.verify.minCount}"
                ];
                ExecStart = "${verifier}/bin/r2-verify";
              };
            };

            timers."${backupUnit}-verify" = lib.mkIf cfg.backup.verify.enable {
              description = "Schedule the Continuwuity backup check";
              wantedBy = ["timers.target"];
              timerConfig = {
                OnCalendar = cfg.backup.verify.schedule;
                Persistent = true;
                RandomizedDelaySec = "15m";
              };
            };
          };

          virtualisation.quadlet = {
            volumes =
              {${stateVolume} = {};}
              // lib.optionalAttrs cfg.backup.enable {${backupVolume} = {};};

            images.${cfg.containerName}.imageConfig = {
              image = "docker-archive:${image}";
              tag = "localhost/${cfg.containerName}:${image.imageTag}";
            };

            containers.${cfg.containerName} =
              if expose
              then config.services.edge-proxy.exposePodman cfg.containerName matrixContainer (cfg.expose // {inherit (cfg) port;})
              else matrixContainer;
          };
        }
      ];
    };
  };
}
