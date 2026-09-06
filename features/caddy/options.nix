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
        Public IPv4 address that ports 80 and 443 are published on. The host
        must already have it configured. There is only this one address, so no
        IPv4 range can be delegated to Caddy's own network, and IPv4 traffic
        arrives through the published ports. IPv6 is delegated a range and
        routed to Caddy directly.
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
            Private IPv4 range for the proxy's own container network.
            The range falls inside the pools podman
            allocates from, and podman checks for a range already in use
            before allocating another network.
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
            Part of `subnet` that podman allocates from when a container asks
            for no particular address. Addresses outside this range stay free
            for the containers given a fixed address, which podman would
            otherwise hand to whichever container started first.
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
            routed to this host. Containers on that network get addresses
            reachable from the internet, so the proxy is reached without
            publishing a port or translating an address.

            The range must not overlap an address on another interface: podman
            refuses a subnet it can already see on the host.
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
            Part of `subnet` that podman allocates from when a container asks
            for no particular address. Addresses outside this range stay free
            for the containers given a fixed address, `ipv6Address` among them.
          '';
        };
      };
    };

    ipv6Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2001:db8:0:0:c::2";
      description = ''
        Address within `network.v6.subnet` given to the proxy. An AAAA record
        points at it, so it is fixed rather than allocated.
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
        Path, relative to the `secrets` flake input, of the sops file
        containing the Cloudflare API token named by `dnsTokenKey`. The proxy
        runs as a system service, so this file is encrypted to the host key.
      '';
    };

    dnsTokenKey = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare_dns_api_token";
      description = ''
        Key in `secretsFile` containing a Cloudflare API token with
        `Zone.Zone:Read` and `Zone.DNS:Edit` on the zones being certified.
        Caddy uses it to write the DNS-01 challenge record, so a certificate
        can be issued before any traffic arrives.

        Only zones Cloudflare serves can be certified this way. A subdomain
        delegated to other nameservers needs its own arrangement.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Caddy package to run. Defaults to `pkgs.caddy` rebuilt with the
        Cloudflare DNS plugin for certificate issuance and caddy-l4 for
        routing non-HTTP connections on the shared TLS port.
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
          `X-Auth-Request-Preferred-Username` header oauth2-proxy returns.
          Caddy deletes that header from the incoming request and sets it only
          from oauth2-proxy's response, so a visitor cannot claim to be
          someone else.

          A username released on the identity provider can be registered by
          somebody else, who would then match a list that still names it.

          An empty list admits anyone the provider authenticates, which is no
          restriction at all if the provider will sign in any account.
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
