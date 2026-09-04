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
        Name the sign-in service registers with the identity provider, and
        gives when it asks who somebody is.
      '';
    };

    clientSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "oidc_client_secret";
      description = ''
        Key in `auth.secretsFile` holding the secret shared with the identity
        provider. The provider reads the same file, so the value is written
        once.
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
      description = "Filename within the secrets input holding the OAuth client credentials.";
    };

    cookieSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "cookie_secret";
      description = ''
        Key in `auth.secretsFile` holding the secret that signs session
        cookies. Must be 16, 24 or 32 bytes; `openssl rand -base64 32 | tr -- '+/' '-_'`
        produces an acceptable one.
      '';
    };
  };
}
