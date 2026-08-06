# The interface between a container and the reverse proxy in front of it.
#
# A service passes its own quadlet through `exposePodman`, which joins it to a
# network it shares with the proxy and sets labels saying which domain it
# answers to. The proxy reads those labels back off the containers to work out
# what to serve, so a service is described in one place: its own container
# definition.
#
# Each service gets its own network, with just that service and the proxy on
# it. Podman cannot filter traffic within a network, so two services sharing
# one could open connections to each other.
#
# The options live here, alongside the container runtime: a host can then run a
# service with or without a proxy present and still evaluate. `enable` is set by
# whichever profile provides the proxy, and a service that is never wrapped is
# never exposed.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.edge-proxy;
in {
  options.services.edge-proxy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether a reverse proxy is present on this host. Set by the profile
        providing the proxy, not by hand. A service tests it before wrapping a
        container: joining a network no profile declares leaves a quadlet naming
        a network podman cannot find, which fails when the container starts
        rather than when the configuration is built.
      '';
    };

    network = lib.mkOption {
      type = lib.types.str;
      default = "edge";
      description = ''
        Podman network holding the proxy's own addresses, which is how the
        outside reaches it. The networks it shares with the services it fronts
        are named after this one.
      '';
    };

    serviceNetwork = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      description = ''
        Name of the network the proxy shares with one service, as
        `serviceNetwork name`, where `name` is the name the container is
        declared under. The proxy joins every one of them; a service joins
        only its own, and so reaches the proxy and nothing else.
      '';
    };

    exposePodman = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      description = ''
        Wrap a container definition so the proxy will serve it, as
        `exposePodman name container { domain, port, auth }`. Returns the
        definition joined to the network it shares with the proxy, with the
        proxy's labels set; everything else about the container is left alone.

        `name` is the name the container is declared under, which is both what
        the proxy resolves it by and what names their shared network.

        `domain` and `auth` are the host's to set, and a service takes them
        through `lib/exposed-service.nix`; `port` is the service's own.
      '';
    };
  };

  config.services.edge-proxy = {
    serviceNetwork = name: "${cfg.network}-${name}";

    exposePodman = name: container: settings: let
      inherit (settings) domain port auth;
      containerConfig = container.containerConfig or {};
    in
      container
      // {
        containerConfig =
          containerConfig
          // {
            networks = (containerConfig.networks or []) ++ ["${cfg.serviceNetwork name}.network"];

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
