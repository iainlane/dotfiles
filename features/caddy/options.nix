{
  hostConfig,
  lib,
  options,
  ...
}: let
  presence = import ../../lib/presence.nix {inherit lib;};
in {
  options.dotfiles.caddy = {
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

    # Quadlet pairs `Gateway=` and `IPRange=` entries with `Subnet=` entries by
    # position, so each family's settings are given together.
    network = {
      v4 = {
        subnet = lib.mkOption {
          type = lib.types.str;
          default = "10.90.0.0/24";
          description = ''
            Private IPv4 range for the proxy's own network. The addresses never
            leave the host. It falls inside the pools podman allocates from,
            and what keeps the allocator off it is podman's own check for a
            range already in use.
          '';
        };

        gateway = lib.mkOption {
          type = lib.types.str;
          default = "10.90.0.1";
          description = "Address within `subnet` given to the bridge itself.";
        };

        range = lib.mkOption {
          type = lib.types.str;
          default = "10.90.0.128/25";
          description = ''
            Part of `subnet` podman allocates from when a container asks for no
            particular address. Addresses outside it stay free for the services
            that are given a fixed one, which would otherwise be handed to
            whichever container started first.
          '';
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

        range = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "2001:db8:0:0:c::100/120";
          description = ''
            Part of `subnet` podman allocates from when a container asks for no
            particular address. Addresses outside it stay free for the services
            that are given a fixed one, `ipv6Address` among them.
          '';
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
      default = "${hostConfig.name}/host-caddy.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file holding
        the Cloudflare API token named by `dnsTokenKey`. The proxy runs as a
        system service, so this file is encrypted to the host key.
      '';
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

    originAuth.present = presence.option ''
      refusing connections that did not arrive through the content delivery
      network in front of this host
    '';

    auth = {
      present = presence.option ''
        single sign-on for the sites that ask for it, provided by one
        oauth2-proxy the whole host shares
      '';

      allow = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["iainlane"];
        description = ''
          Account names allowed past the sign-in gate, matched against the
          `X-Auth-Request-Preferred-Username` header the sign-in service
          answers with. The proxy drops that header off an incoming request
          and sets it only from that answer, so a visitor cannot claim to be
          someone else.

          A name someone gives up on the identity provider can be taken by
          somebody else, who would then match a list still naming it.

          Empty admits anyone the provider authenticates, which for a
          provider that will sign in any account at all is no restriction.
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

  config.assertions =
    presence.assertions options
    (map (child: ["dotfiles" "caddy" child "present"]) ["auth" "originAuth"]);
}
