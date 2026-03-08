{
  flake.profiles.adsb = {
    homeManagerModule = args: {
      config,
      hostConfig,
      inputs,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.adsb;
      secretsFile = inputs.secrets + "/${cfg.secretsFile}";
      ultrafeederEnvFile = config.sops.templates."adsb-ultrafeeder.env".path;
      feederEnvFile = config.sops.templates."adsb-feeders.env".path;
      ultrafeederContainer = import ./ultrafeeder-container.nix {
        inherit hostConfig lib pkgs;
        envFile = ultrafeederEnvFile;
      };
      piawareContainer = import ./piaware-container.nix {envFile = feederEnvFile;};
      fr24Container = import ./fr24-container.nix {envFile = feederEnvFile;};
      planewatchContainer = import ./planewatch-container.nix {envFile = feederEnvFile;};
      normaliseSshKeyPath = path:
        if lib.hasPrefix "/" path
        then path
        else "${config.home.homeDirectory}/${path}";
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {services.adsb = args;}
        {
          sops = {
            age.sshKeyPaths = map normaliseSshKeyPath cfg.ageSshKeyPaths;

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

          home.packages = with pkgs; [
            fuse-overlayfs
            slirp4netns
          ];

          services.podman = {
            enable = true;
            networks.adsbnet = {
              description = "ADS-B feeder network";
              extraConfig.Service.Environment = {
                PATH = "/usr/local/libexec/podman:/run/wrappers/bin:/usr/bin:/bin:/usr/sbin:/sbin";
              };
            };
            containers = {
              ultrafeeder = ultrafeederContainer;
              piaware = piawareContainer;
              fr24 = fr24Container;
              planewatch = planewatchContainer;
            };
          };
        }
      ];
    };

    systemManagerModule = _: {
      lib,
      username,
      ...
    }: let
      rtlBlacklist = builtins.readFile ./rtl-blacklist.conf;
    in {
      config = {
        users.groups.rtlsdr = {};

        users.users.${username} = {
          autoSubUidGidRange = lib.mkDefault true;
          linger = lib.mkDefault true;
          extraGroups = lib.mkAfter ["rtlsdr"];
        };

        environment.etc."modprobe.d/exclusions-rtl2832.conf".text = rtlBlacklist;
        environment.etc."udev/rules.d/10-rtl-sdr.rules".text = ''
          # RTL-SDR Blog V4 (Realtek 0bda:2838)
          SUBSYSTEMS=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", ENV{ID_SOFTWARE_RADIO}="1", MODE:="0660", GROUP:="rtlsdr"
        '';
      };
    };
  };
}
