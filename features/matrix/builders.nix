# The homeserver's package, its paths, its generated configuration and the
# container that runs it. `default.nix` imports this once and wires the results
# into sops and quadlet, so every value the container and the module both need
# is derived in one place.
{
  config,
  inputs,
  lib,
  pkgs,
  quadlet,
}: let
  cfg = config.dotfiles.matrix;

  secretsFile = inputs.secrets + "/${cfg.secretsFile}";

  package =
    if cfg.package != null
    then cfg.package
    else pkgs.matrix-continuwuity;

  databasePath = "/var/lib/continuwuity";
  configPath = "/etc/continuwuity.toml";
  adminConfigPath = "/etc/continuwuity-admin.toml";
  stateVolume = "matrix-state";

  backup = import ./backup/paths.nix;

  inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

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
      # `server_name` identifies the homeserver, which answers at
      # `expose.domain`. These documents tell clients and other
      # homeservers which name to connect to, and are fetched from the
      # identity domain, which redirects here.
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
        # Registration is gated on a token. The agent's account is created
        # administratively by `adminCommands` below; anyone with the token can
        # create an account from a Matrix client, so no password has to pass
        # through the logs.
        allow_registration = true;
        # The account-creation commands run on every start and fail once
        # the account exists. Ignoring an admin command's failure is what
        # keeps the homeserver up on the second boot.
        admin_execute_errors_ignore = true;
        trusted_servers = [];
      }
      // lib.optionalAttrs (wellKnown != {}) {well_known = wellKnown;}
      // lib.optionalAttrs cfg.backup.present {
        database_backup_path = backup.path;
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

  healthUrl = "http://127.0.0.1:${toString cfg.port}/_matrix/client/versions";

  matrixContainer = {
    autoStart = true;

    containerConfig = {
      image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;

      userns = "auto";

      entrypoint = "${package}/bin/conduwuit";
      exec = "--config ${configPath} --config ${adminConfigPath}";

      volumes =
        quadlet.mounts [
          {
            source.quadletVolume = stateVolume;
            target = databasePath;
            ownership = "idmap";
          }
          {
            source.bind = configFile;
            target = configPath;
            readOnly = true;
          }
          {
            source.bind = config.sops.templates."continuwuity-admin.toml".path;
            target = adminConfigPath;
            ownership = "idmap";
            readOnly = true;
          }
        ]
        ++ lib.optionals cfg.backup.present (quadlet.mounts [
          {
            source.quadletVolume = backup.volume;
            target = backup.path;
            ownership = "idmap";
          }
        ]);

      environments.HOME = databasePath;

      dropCapabilities = ["ALL"];
      noNewPrivileges = true;

      # Report ready only once Continuwuity answers, so the proxy and anything
      # else ordered after the homeserver wait until it is reachable.
      notify = "healthy";
      healthCmd = "${pkgs.curl}/bin/curl -fsS ${healthUrl}";
      healthInterval = "5s";
      healthTimeout = "5s";
      healthRetries = 6;
      healthStartPeriod = "60s";
    };

    unitConfig = {
      Description = "Continuwuity Matrix homeserver";
      After = ["network-online.target" "sops-install-secrets.service"];
      Wants = ["network-online.target" "sops-install-secrets.service"];
    };
  };
in {
  inherit
    adminCommands
    image
    matrixContainer
    secretsFile
    stateVolume
    supportUsers
    ;
}
