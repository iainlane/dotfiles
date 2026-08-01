{lib, ...}: {
  options.services.caddy-proxy = {
    enable = lib.mkEnableOption "the Caddy reverse proxy fronting container services";

    ipv4Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "203.0.113.10";
      description = ''
        Public IPv4 address ports 80 and 443 are published on. The host must
        already hold it. A single address cannot be a network of its own, so
        IPv4 reaches the proxy by publishing rather than by routing.
      '';
    };

    # Quadlet pairs `Gateway=` entries with `Subnet=` entries by position, so
    # each family's subnet and its gateway are set together.
    network = {
      v4 = {
        subnet = lib.mkOption {
          type = lib.types.str;
          default = "10.90.0.0/24";
          description = ''
            Private IPv4 range for the shared network. Only carries traffic
            between the proxy and the services it fronts, so the addresses never
            leave the host. Outside podman's own pool, so its allocator cannot
            hand the same range to another network.
          '';
        };

        gateway = lib.mkOption {
          type = lib.types.str;
          default = "10.90.0.1";
          description = "Address within `subnet` given to the bridge itself.";
        };
      };

      v6 = {
        subnet = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "2001:db8:0:0:c::/80";
          description = ''
            Public IPv6 range for the shared network, delegated from a prefix
            routed to this host. Containers on it hold addresses reachable from
            the internet, so the proxy is served without publishing or
            translation.

            It must not overlap an address on another interface: podman refuses a
            subnet it can already see on the host.
          '';
        };

        gateway = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "2001:db8:0:0:c::1";
          description = "Address within `subnet` given to the bridge itself.";
        };
      };
    };

    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2001:db8:0:0:c::2";
      description = ''
        Address within `network.v6.subnet` the proxy holds. This is what an AAAA
        record points at, so it is fixed rather than allocated.
      '';
    };

    email = lib.mkOption {
      type = lib.types.str;
      example = "you@example.org";
      description = "Contact address given to the ACME provider for expiry notices.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Filename within the secrets input holding the proxy's own secrets.";
    };

    dnsTokenKey = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare_dns_api_token";
      description = ''
        Key in `secretsFile` holding a Cloudflare API token with `Zone.Zone:Read`
        and `Zone.DNS:Edit` on the zones being certified. Caddy answers the ACME
        DNS-01 challenge with it, so a certificate can be issued before any
        traffic can arrive.

        Only zones Cloudflare serves can be certified this way. A subdomain
        delegated to other nameservers needs its own arrangement.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Caddy package to run. Defaults to `pkgs.caddy` rebuilt with the
        Cloudflare DNS plugin.
      '';
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "caddy";
      description = "Name of the Caddy podman container.";
    };

    auth = {
      enable = lib.mkEnableOption ''
        single sign-on for sites that ask for it, provided by one oauth2-proxy
        the whole host shares. Sites opt in individually: some must stay
        reachable unauthenticated, and a proxy that quietly authenticates them
        breaks them in ways that are hard to attribute
      '';

      domain = lib.mkOption {
        type = lib.types.str;
        example = "auth.example.org";
        description = ''
          Public host name the sign-in service answers to. Every protected site
          sends unauthenticated visitors here, so this is the only address the
          identity provider needs as a callback, however many sites are
          protected. GitHub allows an OAuth app exactly one.

          It must share a parent domain with the sites it protects, since the
          session cookie is scoped to that parent.
        '';
      };

      cookieDomain = lib.mkOption {
        type = lib.types.str;
        example = ".example.org";
        description = ''
          Domain the session cookie is scoped to. Must be a parent of both
          `domain` and every protected site, or a visitor signing in at the
          former is not recognised at the latter.
        '';
      };

      secretsFile = lib.mkOption {
        type = lib.types.str;
        description = "Filename within the secrets input holding the OAuth client credentials.";
      };

      clientIdKey = lib.mkOption {
        type = lib.types.str;
        default = "client_id";
        description = "Key in `auth.secretsFile` holding the OAuth application's client ID.";
      };

      clientSecretKey = lib.mkOption {
        type = lib.types.str;
        default = "client_secret";
        description = "Key in `auth.secretsFile` holding the OAuth application's client secret.";
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

      githubUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["iainlane"];
        description = ''
          GitHub accounts allowed to sign in. Leave empty and any GitHub account
          is accepted, which is rarely what you want on a personal host.
        '';
      };

      containerName = lib.mkOption {
        type = lib.types.str;
        default = "oauth2-proxy";
        description = "Name of the oauth2-proxy podman container, and the host it is reached at on the shared network.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 4180;
        description = "Port oauth2-proxy listens on inside its container.";
      };
    };
  };
}
