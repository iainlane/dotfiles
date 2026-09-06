# The Home Assistant integration: a long-lived token and base URL handed to the
# agent so it can receive events and drive devices.
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
  hassSecretsFile = inputs.secrets + "/${cfg.homeassistant.secretsFile}";
in {
  options.dotfiles.hermes.homeassistant.secretsFile = lib.mkOption {
    type = lib.types.str;
    default = cfg.secretsFile;
    defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
    description = ''
      Path, relative to the `secrets` flake input, of the sops file containing
      `hass_token` (a Home Assistant long-lived access token) and `hass_url`
      (the Home Assistant base URL, e.g. `http://homeassistant.local:8123`).
    '';
  };

  config = {
    dotfiles.hermes.homeassistant.present = true;

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

    dotfiles.hermes.environmentFiles = [
      config.sops.templates."hermes-homeassistant.env".path
    ];
  };
}
