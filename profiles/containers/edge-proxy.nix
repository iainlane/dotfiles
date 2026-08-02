# The interface between a container and the reverse proxy in front of it.
#
# A service passes its own quadlet through `exposePodman`, which joins it to the
# shared network and labels it with the name it should answer to. The proxy
# discovers what to serve by reading those labels back off the containers, so
# the container definition stays the single description of the service and
# neither side names the other.
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
        Podman network shared between the proxy and the services it fronts. A
        wrapped container joins this network in addition to its own private
        ones, so the proxy resolves it by container name and nothing needs to be
        published to the host.
      '';
    };

    exposePodman = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      description = ''
        Wrap a container definition so the proxy will serve it, as
        `exposePodman container { domain, port, auth }`. Returns the definition
        with the shared network added and the proxy's labels set; everything
        else about the container is left alone.

        `domain` and `auth` are the host's to set, and a service takes them
        through `lib/exposed-service.nix`; `port` is the service's own.
      '';
    };
  };

  config.services.edge-proxy = {
    exposePodman = container: settings: let
      inherit (settings) domain port auth;
      containerConfig = container.containerConfig or {};
    in
      container
      // {
        containerConfig =
          containerConfig
          // {
            networks = (containerConfig.networks or []) ++ ["${cfg.network}.network"];

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
