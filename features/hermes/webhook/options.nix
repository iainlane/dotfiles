{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes.webhook = {
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = "Whether the signing secret is present and the webhook listener is configured.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8644;
      description = "Port the listener binds inside the gateway container.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = "Path, relative to the `secrets` flake input, of the sops file containing the webhook signing secret.";
    };

    secretKey = lib.mkOption {
      type = lib.types.str;
      default = "webhook_secret";
      description = "Key in `webhook.secretsFile` containing the webhook signing secret.";
    };

    expose = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (import ../../../lib/exposed-service.nix));
      default = null;
      description = "How the reverse proxy serves the signed webhook listener.";
    };
  };
}
