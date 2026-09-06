# The interface between an application and the identity provider that
# authenticates its users.
#
# One feature provides the identity: it sets `enable` and `issuer`, and serves
# the endpoints an application discovers from that URL. Applications register
# themselves under `clients`, saying where they may be sent back to and where
# their half of the shared secret is kept.
#
# The options live here, alongside the container runtime, so an application can
# be configured with or without a provider present and still evaluate, and
# neither feature has to reach into the other's options.
{lib, ...}: {
  options.dotfiles.containers.identityProvider = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether an identity provider is present on this host. The feature
        providing it sets this option, not the host configuration. An
        application checks it before registering a client, because `issuer` is
        null when no provider is present and there is no discovery URL to
        configure the application with.
      '';
    };

    issuer = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = ''
        The URL applications know the provider by, and the base they fetch
        `/.well-known/openid-configuration` from to find its other endpoints.
        Applications also check a token's `iss` claim against it, so it has to
        be the name the provider is actually reached at.
      '';
    };

    clients = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Name shown to someone being asked to sign in.";
          };

          redirectURIs = lib.mkOption {
            type = with lib.types; listOf str;
            example = ["https://example.org/oauth2/callback"];
            description = ''
              Callback URLs to which the provider may redirect the browser
              after sign-in. The provider rejects other redirect URLs so the
              authorisation response is sent only to a registered callback.
            '';
          };

          secretsFile = lib.mkOption {
            type = lib.types.str;
            example = "ancaster/host-oauth2-proxy.yaml";
            description = ''
              Path, relative to the `secrets` flake input, of the sops file
              containing this client's secret. The secret belongs to the
              application, and the provider reads the same file, so the value
              is written once.
            '';
          };

          secretKey = lib.mkOption {
            type = lib.types.str;
            example = "oidc_client_secret";
            description = "Key in `secretsFile` containing the secret.";
          };
        };
      }));
      default = {};
      description = ''
        Applications allowed to ask the provider who someone is, keyed by
        client ID. Each application module registers its own client here,
        alongside the rest of that application's configuration.
      '';
    };
  };
}
