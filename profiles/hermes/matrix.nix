# The Matrix platform: a Continuwuity homeserver sidecar the agent reaches over
# a private podman network, plus the password the agent logs in with. The bot
# account is created by the homeserver at startup via its admin command;
# registration is token-gated so further accounts can be made from a client.
#
# The homeserver reports readiness through a healthcheck (`Notify=healthy`), so
# `podman-matrix.service` only becomes active once Continuwuity answers, and a
# homeserver that never becomes healthy fails the deploy.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit
    (import ./builders.nix {inherit config inputs lib pkgs;})
    mkNixImage
    hermesUser
    hermesUserNS
    hermesNss
    hardeningPodmanArgs
    ;

  continuwuityPackage =
    if cfg.matrix.package != null
    then cfg.matrix.package
    else pkgs.matrix-continuwuity;
  matrixStateVolume = "matrix-state";
  matrixDatabasePath = "/var/lib/continuwuity";
  matrixConfigPath = "/etc/continuwuity.toml";
  matrixAdminConfigPath = "/etc/continuwuity-admin.toml";
  matrixSecretsFile = inputs.secrets + "/${cfg.matrix.secretsFile}";
  matrixHealthUrl = "http://127.0.0.1:${toString cfg.matrix.port}/_matrix/client/versions";
  matrixConfigFile = (pkgs.formats.toml {}).generate "continuwuity.toml" {
    global =
      {
        server_name = cfg.matrix.serverName;
        address = ["0.0.0.0"];
        port = [cfg.matrix.port];
        database_path = matrixDatabasePath;
        allow_federation = false;
        # Token-gated registration: the bot is still created administratively
        # (see the admin overlay), and registration is open to anyone holding
        # the registration token, so accounts can be made from a Matrix client
        # without the password ever passing through the logs.
        allow_registration = true;
        # The bot-creation command is idempotent: it errors once the account
        # exists. Ignoring that error keeps the homeserver up on later boots.
        admin_execute_errors_ignore = true;
        trusted_servers = [];
      }
      // cfg.matrix.settings;
  };
  matrixImage = mkNixImage cfg.matrix.containerName [
    continuwuityPackage
    pkgs.coreutils
    pkgs.curl
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    hermesNss
  ];
  matrixImageRef = "localhost/${cfg.matrix.containerName}:${matrixImage.imageTag}";
  matrixImageUnit = "podman-${cfg.matrix.containerName}-image.service";
  # Admin commands the homeserver runs at startup: always create the bot, then
  # any extra accounts, granting admin where asked. Passwords arrive as sops
  # placeholders, substituted when the overlay below is rendered.
  matrixAdminCommands =
    ["users create_user ${cfg.matrix.username} ${config.sops.placeholder.matrix_password}"]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: user:
          ["users create_user ${name} ${config.sops.placeholder.${user.passwordKey}}"]
          ++ lib.optional user.admin "users make-user-admin ${name}"
      )
      cfg.matrix.provisionUsers
    );
  matrixAdminExecuteToml = "[" + lib.concatMapStringsSep ", " (command: ''"${command}"'') matrixAdminCommands + "]";
in {
  config = lib.mkIf (cfg.enable && cfg.matrix.enable) {
    services.hermes-agent = {
      extraDependencyGroups = ["matrix"];
      environment =
        {
          MATRIX_HOMESERVER = cfg.matrix.httpUrl;
          MATRIX_USER_ID = "@${cfg.matrix.username}:${cfg.matrix.serverName}";
        }
        // lib.optionalAttrs (cfg.matrix.homeRoom != "") {
          MATRIX_HOME_ROOM = cfg.matrix.homeRoom;
        }
        // lib.optionalAttrs cfg.matrix.encryption.enable {
          MATRIX_ENCRYPTION = "true";
          MATRIX_DEVICE_ID = cfg.matrix.encryption.deviceId;
        };
      environmentFiles = [config.sops.templates."hermes-matrix.env".path];
    };

    sops = {
      secrets =
        {
          matrix_password.sopsFile = matrixSecretsFile;
          matrix_allowed_users.sopsFile = matrixSecretsFile;
          matrix_registration_token.sopsFile = matrixSecretsFile;
        }
        // lib.optionalAttrs (cfg.matrix.encryption.enable && cfg.matrix.encryption.recoveryKeyKey != null) {
          ${cfg.matrix.encryption.recoveryKeyKey}.sopsFile = matrixSecretsFile;
        }
        // lib.mapAttrs' (
          _: user: lib.nameValuePair user.passwordKey {sopsFile = matrixSecretsFile;}
        )
        cfg.matrix.provisionUsers;

      # The agent logs in by password; the user ID and home room are not secret
      # and ride along as plain environment.
      templates."hermes-matrix.env".content =
        ''
          MATRIX_PASSWORD=${config.sops.placeholder.matrix_password}
          MATRIX_ALLOWED_USERS=${config.sops.placeholder.matrix_allowed_users}
        ''
        + lib.optionalString (cfg.matrix.encryption.enable && cfg.matrix.encryption.recoveryKeyKey != null) ''
          MATRIX_RECOVERY_KEY=${config.sops.placeholder.${cfg.matrix.encryption.recoveryKeyKey}}
        '';

      # A config overlay carrying the one secret-bearing setting: the startup
      # admin command that creates the bot. Living in this mode-restricted file
      # keeps the password out of the world-readable store and process arguments.
      templates."continuwuity-admin.toml".content = ''
        [global]
        registration_token = "${config.sops.placeholder.matrix_registration_token}"
        admin_execute = ${matrixAdminExecuteToml}
      '';
    };

    services.podman = {
      volumes.${matrixStateVolume} = {
        description = "Continuwuity homeserver state and database";
      };

      networks.${cfg.matrix.network} = {
        description = "Hermes and Continuwuity homeserver network";
        extraConfig.Service.Environment = {
          PATH = "/usr/local/libexec/podman:/run/wrappers/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        };
      };

      images.${cfg.matrix.containerName} = {
        image = "docker-archive:${matrixImage}";
        autoStart = true;
      };

      containers.${cfg.matrix.containerName} = {
        autoStart = true;
        description = "Continuwuity Matrix homeserver for Hermes";
        image = matrixImageRef;
        user = hermesUser;
        userNS = hermesUserNS;
        entrypoint = "${continuwuityPackage}/bin/conduwuit";
        exec = "--config ${matrixConfigPath} --config ${matrixAdminConfigPath}";
        network = ["${cfg.matrix.network}.network"];
        ports = ["${cfg.matrix.listenAddress}:${toString cfg.matrix.port}:${toString cfg.matrix.port}"];
        volumes = [
          "${matrixStateVolume}.volume:${matrixDatabasePath}"
          "${matrixConfigFile}:${matrixConfigPath}:ro"
          "${config.sops.templates."continuwuity-admin.toml".path}:${matrixAdminConfigPath}:ro"
        ];
        environment.HOME = matrixDatabasePath;
        dropCapabilities = ["ALL"];
        extraPodmanArgs = hardeningPodmanArgs;
        extraConfig = {
          Container = {
            # Report ready only once Continuwuity answers, so dependants wait
            # for the homeserver to be reachable before they start.
            Notify = "healthy";
            HealthCmd = "${pkgs.curl}/bin/curl -fsS ${matrixHealthUrl}";
            HealthInterval = "5s";
            HealthTimeout = "5s";
            HealthRetries = "6";
            HealthStartPeriod = "60s";
          };
          Unit = {
            After = ["network-online.target" "sops-nix.service" matrixImageUnit];
            Wants = ["network-online.target" "sops-nix.service" matrixImageUnit];
          };
          Service = {
            Environment = [
              "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
            ];
          };
        };
      };
    };
  };
}
