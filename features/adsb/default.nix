# The ADS-B feeder stack: an ultrafeeder decoding from the RTL-SDR, and one
# container per aggregator relaying from it.
#
# These run rootful. The feeders need the reverse proxy to resolve them by
# container name, and a rootless bridge lives in a network namespace the host
# cannot route into, so the whole stack sits on a rootful netavark bridge.
{config, ...}: {
  flake.features.adsb = {
    includes = [config.flake.features.containers];

    systemManager = {
      config,
      exposePodman,
      hostConfig,
      inputs,
      lib,
      pkgs,
      quadlet,
      ...
    }: let
      cfg = config.dotfiles.adsb;
      secretsFile = inputs.secrets + "/${cfg.secretsFile}";
      ultrafeederEnvFile = config.sops.templates."adsb-ultrafeeder.env".path;
      feederEnvFile = config.sops.templates."adsb-feeders.env".path;

      network = config.virtualisation.quadlet.networks.adsbnet.ref;

      # Quadlet names a container's unit after its quadlet file, with no
      # prefix, so the relaying feeders order themselves against this.
      ultrafeederName = "ultrafeeder";
      ultrafeederService = "${ultrafeederName}.service";

      # A page reaches the outside through the proxy alone. The host decides
      # the public name and whether to require sign-in; the port each page is
      # served on inside its container is ours to know.
      served = expose: port: container:
        if expose != null && config.dotfiles.containers.edgeProxy.enable
        then name: exposePodman name container (expose // {inherit port;})
        else _: container;

      ultrafeederContainer = import ./ultrafeeder-container.nix {
        inherit hostConfig lib network pkgs quadlet volumes;
        envFile = ultrafeederEnvFile;
      };
      piawareContainer = import ./piaware-container.nix {
        inherit network ultrafeederService;
        envFile = feederEnvFile;
      };
      fr24Container = import ./fr24-container.nix {
        inherit network ultrafeederService;
        envFile = feederEnvFile;
      };
      planewatchContainer = import ./planewatch-container.nix {
        inherit network ultrafeederService;
        envFile = feederEnvFile;
      };

      # The ultrafeeder's own volumes carry the host name, so several feeders
      # backed by one podman could coexist.
      volumes = {
        globeHistory = "adsb-${hostConfig.hostname}-globe-history";
        graphs = "adsb-${hostConfig.hostname}-graphs1090";
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          # The DVB kernel drivers claim the SDR unless they are kept away
          # from it.
          environment.etc."modprobe.d/exclusions-rtl2832.conf".source = ./rtl-blacklist.conf;

          # rtl-sdr's own rules give the device node to the `plugdev` group,
          # and carry the ids of every dongle the library supports.
          environment.etc."udev/rules.d/60-rtl-sdr.rules".source = "${pkgs.rtl-sdr}/etc/udev/rules.d/rtl-sdr.rules";

          sops = {
            secrets = {
              latitude.sopsFile = secretsFile;
              longitude.sopsFile = secretsFile;
              altitude.sopsFile = secretsFile;
              piaware_feeder_id.sopsFile = secretsFile;
              fr24_sharing_key.sopsFile = secretsFile;
              planewatch_api_key.sopsFile = secretsFile;
            };

            templates."adsb-ultrafeeder.env".content = ''
              READSB_LAT=${config.sops.placeholder.latitude}
              READSB_LON=${config.sops.placeholder.longitude}
              READSB_ALT=${config.sops.placeholder.altitude}m
            '';

            templates."adsb-feeders.env".content = ''
              FEEDER_ID=${config.sops.placeholder.piaware_feeder_id}
              FR24KEY=${config.sops.placeholder.fr24_sharing_key}
              API_KEY=${config.sops.placeholder.planewatch_api_key}
              LAT=${config.sops.placeholder.latitude}
              LONG=${config.sops.placeholder.longitude}
              ALT=${config.sops.placeholder.altitude}m
            '';
          };

          virtualisation.quadlet = {
            networks.adsbnet = {};

            volumes = {
              ${volumes.globeHistory} = {};
              ${volumes.graphs} = {};
            };

            containers = {
              ${ultrafeederName} = served cfg.expose 80 ultrafeederContainer ultrafeederName;
              piaware = served cfg.piaware.expose 80 piawareContainer "piaware";
              fr24 = served cfg.fr24.expose 8754 fr24Container "fr24";
              planewatch = planewatchContainer;
            };
          };
        }
      ];
    };
  };
}
