# The interface between an application and whatever tells it who someone is.
#
# One profile provides the identity: it sets `enable` and `issuer`, and serves
# the endpoints an application discovers from that URL. Applications register
# themselves under `clients`, saying where they may be sent back to and where
# their half of the shared secret is kept.
#
# The options live here, alongside the container runtime, so an application can
# be configured with or without a provider present and still evaluate, and
# neither profile has to reach into the other's options.
{lib, ...}: {
  options.services.identity-provider = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether an identity provider is present on this host. Set by the
        profile providing it, not by hand. An application tests it before
        registering, since a client registered with nothing to serve it would
        leave the application asking an address that answers nothing.
      '';
    };

    issuer = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = ''
        The URL applications know the provider by, and where they fetch
        `/.well-known/openid-configuration` to find the rest of it. It is also
        the value they check a token's `iss` claim against, so it has to be the
        name the provider is reached at.
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
              Addresses the provider will return someone to once they have
              signed in. Anywhere else is refused, which is what stops a stolen
              authorisation code being redeemed somewhere the application does
              not control.
            '';
          };

          secretsFile = lib.mkOption {
            type = lib.types.str;
            example = "ancaster/host-oauth2-proxy.yaml";
            description = ''
              Path, relative to the `secrets` flake input, of the sops file
              holding this client's secret. It belongs to the application, and
              the provider reads the same file, so the value is written once.
            '';
          };

          secretKey = lib.mkOption {
            type = lib.types.str;
            example = "oidc_client_secret";
            description = "Key in `secretsFile` holding the secret.";
          };
        };
      }));
      default = {};
      description = ''
        Applications allowed to ask the provider who someone is, keyed by
        client ID. Each registers itself where it is configured, so the two
        ends cannot come to disagree about the other.
      '';
    };
  };
}
