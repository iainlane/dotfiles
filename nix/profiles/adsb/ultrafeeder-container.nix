{
  hostConfig,
  lib,
  pkgs,
  envFile,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder
  image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest-build-897@sha256:1f99603ea0dd461622e1751c794ec5701eff944fe86455f91fb02bc27164a5aa";
  httpPort = 8080;
  rtlSerial = "00000001";
  timezone = "UTC";

  ultrafeederTargets = import ./ultrafeeder-config.nix;
  mlathubTargets = import ./ultrafeeder-mlathub-config.nix;
  runtimeEnvFile = "%t/adsb/ultrafeeder-runtime.env";
  targetsCsv = lib.concatStringsSep ";" (map (target: "${target.name},${target.adsbHost},${toString target.adsbPort},${target.mlatHost},${toString target.mlatPort}") ultrafeederTargets);
  mlathubTargetsCsv = lib.concatStringsSep ";" (map (target: "${target.name},${target.host},${toString target.port},${target.protocol}") mlathubTargets);
  runtimeConfigBuilder = pkgs.writeShellScript "adsb-build-ultrafeeder-env" (builtins.readFile ./build-ultrafeeder-env.sh);

  volumePrefix = "adsb-${hostConfig.hostname}";
  feederName = hostConfig.hostname;
in {
  autoStart = true;
  description = "ADS-B feeder and local visualisation";
  inherit image;
  network = "adsbnet.network";
  extraPodmanArgs = ["--group-add=keep-groups"];
  ports = ["${toString httpPort}:80"];

  environment = {
    LOGLEVEL = "error";
    TZ = timezone;
    READSB_DEVICE_TYPE = "rtlsdr";
    READSB_RTLSDR_DEVICE = rtlSerial;
    READSB_GAIN = "auto";
    READSB_RX_LOCATION_ACCURACY = "2";
    READSB_STATS_RANGE = "true";
    MLAT_USER = feederName;
    READSB_FORWARD_MLAT_SBS = "true";
    UPDATE_TAR1090 = "true";
    TAR1090_MESSAGERATEINTITLE = "true";
    TAR1090_PAGETITLE = feederName;
    TAR1090_PLANECOUNTINTITLE = "true";
    TAR1090_ENABLE_AC_DB = "true";
    TAR1090_FLIGHTAWARELINKS = "true";
    TAR1090_SITESHOW = "true";
    TAR1090_RANGE_OUTLINE_COLORED_BY_ALTITUDE = "true";
    TAR1090_RANGE_OUTLINE_WIDTH = "2.0";
    TAR1090_RANGERINGSDISTANCES = "50,100,150,200";
    TAR1090_USEROUTEAPI = "true";
    GRAPHS1090_DARKMODE = "true";
  };

  volumes = [
    # Bind-mount USB bus so re-enumerated device nodes remain visible.
    "/dev/bus/usb:/dev/bus/usb"
    "${volumePrefix}-globe-history:/var/globe_history"
    "${volumePrefix}-graphs1090:/var/lib/collectd"
    "/proc/diskstats:/proc/diskstats:ro"
  ];

  extraConfig = {
    Container = {
      EnvironmentFile = [
        envFile
        runtimeEnvFile
      ];
      Tmpfs = [
        "/run:exec,size=256M"
        "/tmp:size=128M"
        "/var/log:size=32M"
      ];
    };
    Unit = {
      After = [
        "network-online.target"
        "sops-nix.service"
      ];
      Wants = [
        "network-online.target"
        "sops-nix.service"
      ];
    };
    Service = {
      ExecStartPre = ["${runtimeConfigBuilder}"];
      Environment = [
        "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        "ADSB_TARGETS=${targetsCsv}"
        "MLATHUB_TARGETS=${mlathubTargetsCsv}"
      ];
    };
  };
}
