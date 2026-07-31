{
  hostConfig,
  lib,
  pkgs,
  envFile,
  network,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder
  image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest-build-897@sha256:1f99603ea0dd461622e1751c794ec5701eff944fe86455f91fb02bc27164a5aa";
  httpPort = 8082;
  rtlSerial = "00000001";
  timezone = "UTC";

  ultrafeederTargets = import ./ultrafeeder-config.nix;
  mlathubTargets = import ./ultrafeeder-mlathub-config.nix;
  runtimeDirectory = "adsb";
  runtimeEnvFile = "/run/${runtimeDirectory}/ultrafeeder-runtime.env";
  targetsCsv = lib.concatStringsSep ";" (map (target: "${target.name},${target.adsbHost},${toString target.adsbPort},${target.mlatHost},${toString target.mlatPort}") ultrafeederTargets);
  mlathubTargetsCsv = lib.concatStringsSep ";" (map (target: "${target.name},${target.host},${toString target.port},${target.protocol}") mlathubTargets);
  runtimeConfigBuilder = pkgs.writeShellScript "adsb-build-ultrafeeder-env" (builtins.readFile ./build-ultrafeeder-env.sh);

  volumePrefix = "adsb-${hostConfig.hostname}";
  feederName = hostConfig.hostname;
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];
    publishPorts = ["${toString httpPort}:80"];

    # The USB bus is bind-mounted so the container keeps seeing the SDR across
    # re-enumeration, which moves its bus and device numbers. A bind mount
    # carries no cgroup device permission, so opening the node is denied until
    # the whole USB major is allowed.
    podmanArgs = ["--device-cgroup-rule=c 189:* rwm"];

    environments = {
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

    environmentFiles = [
      envFile
      runtimeEnvFile
    ];

    volumes = [
      # Bind-mount USB bus so re-enumerated device nodes remain visible.
      "/dev/bus/usb:/dev/bus/usb"
      "${volumePrefix}-globe-history:/var/globe_history"
      "${volumePrefix}-graphs1090:/var/lib/collectd"
      "/proc/diskstats:/proc/diskstats:ro"
    ];

    tmpfses = [
      "/run:exec,size=256M"
      "/tmp:size=128M"
      "/var/log:size=32M"
    ];
  };

  unitConfig = {
    Description = "ADS-B feeder and local visualisation";
    After = ["network-online.target" "sops-install-secrets.service"];
    Wants = ["network-online.target" "sops-install-secrets.service"];
  };

  serviceConfig = {
    # Creates /run/adsb and hands the path to the builder as RUNTIME_DIRECTORY.
    RuntimeDirectory = runtimeDirectory;
    ExecStartPre = ["${runtimeConfigBuilder}"];
    Environment = [
      "ADSB_TARGETS=${targetsCsv}"
      "MLATHUB_TARGETS=${mlathubTargetsCsv}"
    ];
  };
}
