# The Home Assistant integration: a long-lived token and base URL handed to the
# agent so it can receive events and drive devices.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.services.hermes-agent;
  hassSecretsFile = inputs.secrets + "/${cfg.homeassistant.secretsFile}";
in {
  config = lib.mkIf (cfg.enable && cfg.homeassistant.enable) {
    sops = {
      secrets = {
        hass_token.sopsFile = hassSecretsFile;
        hass_url.sopsFile = hassSecretsFile;
      };

      templates."hermes-homeassistant.env".content = ''
        HASS_TOKEN=${config.sops.placeholder.hass_token}
        HASS_URL=${config.sops.placeholder.hass_url}
      '';
    };

    services.hermes-agent.environmentFiles = [
      config.sops.templates."hermes-homeassistant.env".path
    ];
  };
}
