# The ADS-B feeder stack: an ultrafeeder decoding from the RTL-SDR, and one
# container per aggregator relaying from it.
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

      # The relaying feeders reach the ultrafeeder by container name, and they
      # write that name into their own `BEASTHOST`, so renaming it here alone
      # breaks them.
      ultrafeederName = "ultrafeeder";
      ultrafeederService = "${ultrafeederName}.service";

      # A page is exposed to the outside only through the proxy. The host sets
      # the public name and whether to require sign-in, and this feature sets
      # the port the page listens on inside its container.
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

      # The ultrafeeder's own volumes are named after the host, so more than
      # one feeder could share a single podman installation.
      volumes = {
        globeHistory = "adsb-${hostConfig.hostname}-globe-history";
        graphs = "adsb-${hostConfig.hostname}-graphs1090";
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          # The DVB kernel drivers bind to the SDR if they are allowed to
          # load, so they are blacklisted.
          #
          # `builtins.path` copies this one file to a store path of its own.
          # Using `./rtl-blacklist.conf` directly would refer to a path inside
          # the flake's own source tree, so the rendered /etc entry would
          # change with every commit to the repository.
          environment.etc."modprobe.d/exclusions-rtl2832.conf".source = builtins.path {
            path = ./rtl-blacklist.conf;
            name = "rtl-blacklist.conf";
          };

          # and list the ids of every dongle the library supports.
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
