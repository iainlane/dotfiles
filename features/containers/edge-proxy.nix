# The interface between a container and the reverse proxy in front of it.
#
# A service passes its own quadlet through `exposePodman`, which joins it to a
# network shared with the proxy and sets labels giving its domain. The proxy
# reads those labels back off the containers to work out what to serve, so a
# service is described in one place: its own container definition.
#
# Each service gets its own network, with just that service and the proxy on
# it. podman cannot filter traffic within a network, so two services sharing
# one could open connections to each other.
#
# The options live here, alongside the container runtime: a host can then run a
# service with or without a proxy present and still evaluate. `enable` is set by
# whichever feature provides the proxy, and a service that is never wrapped is
# never exposed.
{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.containers.edgeProxy;
in {
  options.dotfiles.containers.edgeProxy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether a reverse proxy is present on this host. Set by the feature
        providing the proxy, not by hand. A service tests it before attaching a
        container to the proxy network. Without that test the quadlet would
        reference an undeclared network, and the failure would appear when
        podman starts the container, after the configuration had built
        successfully.
      '';
    };

    unit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = ''
        The systemd unit the proxy runs as, defined by the feature providing
        it. A service that has to reach a name the proxy answers to orders
        itself after this. It has no value on a host without a proxy, so read
        it only when `enable` is true.
      '';
    };

    network = lib.mkOption {
      type = lib.types.str;
      default = "edge";
      description = ''
        The podman network on which the proxy's externally reachable addresses
        are configured. The networks the proxy shares with the services it
        fronts are named after this one.
      '';
    };

    streams = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            example = "pg.example.com";
            description = ''
              The hostname that clients connect to, and the name the proxy
              obtains a certificate for. It must resolve directly to this
              host, so the proxy receives the TLS connection itself and
              selects the service from it. A CDN in front would terminate the
              handshake and forward HTTP, which this service does not speak.
            '';
          };

          alpn = lib.mkOption {
            type = lib.types.str;
            example = "postgresql";
            description = ''
              The protocol the client asks for in the TLS handshake. The proxy
              matches on it to tell these connections from web traffic, so
              both can use the same port.
            '';
          };

          port = lib.mkOption {
            type = lib.types.port;
            description = ''
              The port the service listens on inside its container. The proxy
              connects to it by container name over the network the two of
              them share.
            '';
          };

          trustedClients = lib.mkOption {
            type = with lib.types; listOf str;
            default = [];
            example = lib.literalExpression ''[(builtins.readFile ./client.pem)]'';
            description = ''
              The certificates, in PEM form, that can connect. The proxy
              compares each one in full. It closes a connection that gives a
              different certificate during the handshake. Remove a
              certificate from this list and that machine loses access at the
              next reload.

              These protocols have no sign-in, so this list is the only thing
              deciding who gets access. It cannot be empty.
            '';
          };
        };
      });
      default = {};
      description = ''
        The services that use TLS and do not use HTTP, by container name.

        The proxy terminates TLS on the port that it already uses. It tells
        these services from web traffic by the protocol in the handshake. It
        then passes the decrypted connection to the service.
      '';
    };
  };

  config._module.args = {
    # Name of the network between the proxy and one service. `name` is the
    # attribute name of the container declaration. The proxy joins every one of
    # them; a service joins only its own, and so reaches the proxy and nothing
    # else.
    serviceNetwork = name: "${cfg.network}-${name}";

    # Wrap a container definition so the proxy will serve it, as
    # `exposePodman name container { domain, port, auth }`. It returns the
    # definition joined to the network it shares with the proxy, with the
    # proxy's labels set; everything else about the container is left alone.
    #
    # `name` is the attribute name of the container declaration. The proxy
    # resolves the container by that name, and their shared network is named
    # after it.
    #
    # The host sets `domain` and `auth` through the service's own option from
    # `lib/exposed-service.nix`. The service supplies `port`.
    exposePodman = name: container: settings: let
      inherit (settings) domain port auth;
      containerConfig = container.containerConfig or {};
    in
      container
      // {
        containerConfig =
          containerConfig
          // {
            networks = (containerConfig.networks or []) ++ ["${cfg.network}-${name}.network"];

            labels =
              (containerConfig.labels or {})
              // {
                "edge-proxy.domain" = domain;
                # The port inside the container, which is not necessarily one
                # it publishes to the host.
                "edge-proxy.port" = toString port;
                "edge-proxy.auth" = lib.boolToString auth;
              };
          };
      };
  };
}
