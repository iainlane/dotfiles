# The ADS-B feeder stack: an ultrafeeder decoding from the RTL-SDR, and one
# container per aggregator relaying from it.
#
# These run rootful. The feeders need the reverse proxy to resolve them by
# container name, and a rootless bridge lives in a network namespace the host
# cannot route into, so the whole stack sits on a rootful netavark bridge.
{
  flake.profiles.adsb = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.systemManagerModule = args: {
      config,
      hostConfig,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.adsb;
      rtlBlacklist = builtins.readFile ./rtl-blacklist.conf;
      secretsFile = inputs.secrets + "/${cfg.secretsFile}";
      ultrafeederEnvFile = config.sops.templates."adsb-ultrafeeder.env".path;
      feederEnvFile = config.sops.templates."adsb-feeders.env".path;

      network = config.virtualisation.quadlet.networks.adsbnet.ref;

      # Quadlet names a container's unit after its quadlet file, with no
      # prefix, so the relaying feeders order themselves against this.
      ultrafeederName = "ultrafeeder";
      ultrafeederService = "${ultrafeederName}.service";

      # tar1090 is the only part of the feeder worth reaching from outside, so
      # it is the only container offered to the proxy. The host decides the
      # public name and whether to require sign-in; the port tar1090 listens on
      # is ours to know.
      ultrafeederContainer = import ./ultrafeeder-container.nix {
        inherit hostConfig lib network pkgs;
        envFile = ultrafeederEnvFile;
      };
      exposeUltrafeeder = cfg.expose != null && config.services.edge-proxy.enable;
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
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.adsb = args;}
        {
          # The DVB kernel drivers claim the SDR unless they are kept away
          # from it.
          environment.etc."modprobe.d/exclusions-rtl2832.conf".text = rtlBlacklist;

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

            containers = {
              ${ultrafeederName} =
                if exposeUltrafeeder
                then config.services.edge-proxy.exposePodman ultrafeederName ultrafeederContainer (cfg.expose // {port = 80;})
                else ultrafeederContainer;
              piaware = piawareContainer;
              fr24 = fr24Container;
              planewatch = planewatchContainer;
            };
          };
        }
      ];
    };
  };
}
