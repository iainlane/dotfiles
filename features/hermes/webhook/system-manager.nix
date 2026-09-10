{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit (cfg) webhook;
  secretsPath = inputs.secrets + "/${webhook.secretsFile}";
  available = (import ../../../lib/sops-keys.nix {inherit lib;}).hasKey secretsPath webhook.secretKey;
  exposed = webhook.expose != null && config.dotfiles.containers.edgeProxy.enable;
in {
  config = lib.mkMerge [
    {
      dotfiles.hermes.webhook = {
        present = true;
        active = available;
      };
    }
    (lib.mkIf available {
      dotfiles.hermes = {
        environment.WEBHOOK_ENABLED = "true";
        environmentFiles = [config.sops.templates."hermes-webhook.env".path];
        settings.platforms.webhook = {
          enabled = true;
          extra = {
            inherit (webhook) port;
            host =
              if exposed
              then "0.0.0.0"
              else "127.0.0.1";
          };
        };
      };

      assertions = [
        {
          assertion = webhook.expose == null || !webhook.expose.auth;
          message = ''
            dotfiles.hermes.webhook.expose.auth is on, but webhook senders cannot
            complete a browser sign-in. Disable proxy authentication and rely on
            the signature that Hermes verifies for each request.
          '';
        }
      ];

      sops = {
        secrets.${webhook.secretKey}.sopsFile = secretsPath;
        templates."hermes-webhook.env".content = ''
          WEBHOOK_SECRET=${config.sops.placeholder.${webhook.secretKey}}
        '';
      };
    })
  ];
}
