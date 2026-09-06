{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes.dashboard = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 9119;
      description = "Port the dashboard listens on.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the dashboard binds to when it is not exposed. On loopback
        nothing outside the container reaches it. Setting `expose` binds
        every address instead, and configures the sign-in that Hermes then
        requires.
      '';
    };

    expose = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (import ../../../lib/exposed-service.nix));
      default = null;
      description = ''
        How the reverse proxy serves the dashboard. Hermes requires a sign-in
        but serves anyone the identity provider recognises, so `auth` has to be
        on: the proxy's `auth.allow` list is the only thing limiting who gets
        in.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing the dashboard's half of the secret it shares with the
        identity provider. The provider reads the same file.
      '';
    };

    clientSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "dashboard_oidc_client_secret";
      description = "Key in `dashboard.secretsFile` containing that secret.";
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "hermes-dashboard";
      description = "Name of the dashboard podman container.";
    };
  };
}
