{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.caddy;
in {
  options.dotfiles.caddy.auth = {
    clientId = lib.mkOption {
      type = lib.types.str;
      default = "oauth2-proxy";
      description = ''
        Client ID oauth2-proxy registers with the identity provider and sends
        on every authorisation request.
      '';
    };

    clientSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "oidc_client_secret";
      description = ''
        Key in `auth.secretsFile` containing the secret shared with the
        identity provider. The provider reads the same file, so the value is
        written once.
      '';
    };

    cookieDomain = lib.mkOption {
      type = lib.types.str;
      example = ".example.org";
      description = ''
        Domain the session cookie is scoped to. Must be a parent of every
        protected site, so that signing in at one is recognised at the rest.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.caddy.secretsFile";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing the keys named by `clientSecretKey` and `cookieSecretKey`.
        The identity provider reads the client secret from the same file.
      '';
    };

    cookieSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "cookie_secret";
      description = ''
        Key in `auth.secretsFile` containing the secret that signs session
        cookies. Must be 16, 24 or 32 bytes; `openssl rand -base64 32 | tr -- '+/' '-_'`
        produces an acceptable one.
      '';
    };
  };
}
