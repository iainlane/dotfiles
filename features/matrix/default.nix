# A Continuwuity Matrix homeserver, served through the reverse proxy.
#
# The homeserver owns its own accounts and state and knows nothing about what
# talks to it. Clients reach it at its public name, which is also how the agent
# on this host reaches it.
{config, ...}: {
  imports = [./backup];

  flake.features.matrix = {
    includes = [config.flake.features.containers config.flake.features.matrix.provides.backup];

    systemManager = {
      config,
      exposePodman,
      inputs,
      lib,
      pkgs,
      quadlet,
      ...
    }: let
      cfg = config.dotfiles.matrix;

      inherit
        (import ./builders.nix {inherit config inputs lib pkgs quadlet;})
        adminCommands
        image
        matrixContainer
        secretsFile
        stateVolume
        supportUsers
        ;

      expose = cfg.expose != null && config.dotfiles.containers.edgeProxy.enable;
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = lib.length supportUsers <= 1;
              message = ''
                dotfiles.matrix publishes one support contact, and
                ${lib.concatStringsSep ", " supportUsers} are all marked
                `supportUser`.
              '';
            }
            {
              assertion = cfg.expose == null || !cfg.expose.auth;
              message = ''
                dotfiles.matrix.expose.auth is on, so the proxy would answer
                every Matrix client and every federating homeserver with a
                sign-in page. Matrix authenticates its own clients.
              '';
            }
          ];

          sops = {
            secrets =
              {
                matrix_password.sopsFile = secretsFile;
                matrix_registration_token.sopsFile = secretsFile;
              }
              // lib.mapAttrs' (
                _: user: lib.nameValuePair user.passwordKey {sopsFile = secretsFile;}
              )
              (lib.filterAttrs (_: user: user.passwordKey != null) cfg.users);

            # A config overlay with the settings that contain secrets. sops
            # renders the file at runtime with a restrictive mode, replacing
            # each placeholder with the real value. The store copy therefore
            # contains no passwords, and none are given as process arguments.
            templates."continuwuity-admin.toml" = {
              content = ''
                [global]
                registration_token = ${builtins.toJSON config.sops.placeholder.matrix_registration_token}
                admin_execute = ${builtins.toJSON adminCommands}
              '';
            };
          };

          virtualisation.quadlet = {
            volumes.${stateVolume} = {};

            images.${cfg.containerName}.imageConfig = {
              image = "docker-archive:${image}";
              tag = "localhost/${cfg.containerName}:${image.imageTag}";
            };

            containers.${cfg.containerName} =
              if expose
              then exposePodman cfg.containerName matrixContainer (cfg.expose // {inherit (cfg) port;})
              else matrixContainer;
          };
        }
      ];
    };
  };
}
