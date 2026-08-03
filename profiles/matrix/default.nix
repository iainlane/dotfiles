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
      configPath = "/etc/continuwuity.toml";
      adminConfigPath = "/etc/continuwuity-admin.toml";
      stateVolume = "matrix-state";

      inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

      image = mkNixImage cfg.containerName [
        package
        pkgs.coreutils
        pkgs.curl
        pkgs.dockerTools.binSh
        pkgs.dockerTools.caCertificates
        pkgs.dockerTools.fakeNss
      ];

      configFile = (pkgs.formats.toml {}).generate "continuwuity.toml" {
        global =
          {
            server_name = cfg.serverName;
            address = ["0.0.0.0"];
            port = [cfg.port];
            database_path = databasePath;
            allow_federation = false;
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
          // lib.optionalAttrs (cfg.expose != null) {
            # `server_name` is the identity; the homeserver answers at
            # `expose.domain`. These documents point one at the other. Clients
            # and other homeservers fetch them from the identity domain, which
            # redirects here.
            well_known = {
              client = "https://${cfg.expose.domain}";
              server = "${cfg.expose.domain}:443";
            };
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
            name: user':
              ["users create_user ${name} ${config.sops.placeholder.${user'.passwordKey}}"]
              ++ lib.optional user'.admin "users make-user-admin ${name}"
          )
          cfg.provisionUsers
        );

      matrixContainer = import ./container.nix {
        inherit adminConfigPath configFile configPath databasePath cfg pkgs package stateVolume;
        adminConfigFile = config.sops.templates."continuwuity-admin.toml".path;
        image = config.virtualisation.quadlet.images.${cfg.containerName}.ref;
        networks = [config.virtualisation.quadlet.networks.matrixnet.ref];
      };

      expose = cfg.expose != null && config.services.edge-proxy.enable;
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.continuwuity = args;}
        {
          sops = {
            secrets =
              {
                matrix_password.sopsFile = secretsFile;
                matrix_registration_token.sopsFile = secretsFile;
              }
              // lib.mapAttrs' (
                _: user': lib.nameValuePair user'.passwordKey {sopsFile = secretsFile;}
              )
              cfg.provisionUsers;

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
          };

          virtualisation.quadlet = {
            networks.matrixnet = {};

            volumes.${stateVolume} = {};

            images.${cfg.containerName}.imageConfig = {
              image = "docker-archive:${image}";
              tag = "localhost/${cfg.containerName}:${image.imageTag}";
            };

            containers.${cfg.containerName} =
              if expose
              then config.services.edge-proxy.exposePodman matrixContainer (cfg.expose // {inherit (cfg) port;})
              else matrixContainer;
          };
        }
      ];
    };
  };
}
