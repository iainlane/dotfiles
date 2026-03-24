{
  hostConfig,
  pkgs,
  cfg,
  imagePath,
  imageRef,
  serverVersion,
}: let
  volumePrefix = "unifi-${hostConfig.hostname}";
  runtimeEnvFile = "%t/unifi/runtime.env";

  loadImageScript = pkgs.writeShellApplication {
    name = "unifi-load-image";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnutar
      jq
      podman
      util-linux
    ];
    text = builtins.readFile ./load-image.sh;
  };

  defaultPorts = [
    "${toString cfg.webPort}:443"
    "5005:5005"
    "5671:5671"
    "6789:6789"
    "8080:8080"
    "8443:8443"
    "8444:8444"
    "8880:8880"
    "8881:8881"
    "8882:8882"
    "9543:9543"
    "3478:3478/udp"
    "5514:5514/udp"
    "10001:10001/udp"
    "10003:10003/udp"
  ];
in {
  autoStart = true;
  description = "UniFi OS Server";
  image = imageRef;

  ports = defaultPorts ++ cfg.extraPorts;

  environment = {
    UOS_SERVER_VERSION = serverVersion;
    FIRMWARE_PLATFORM =
      if pkgs.stdenv.hostPlatform.isAarch64
      then "linux-arm64"
      else "linux-x64";
  };

  volumes = [
    "${volumePrefix}-persistent:/persistent"
    "${volumePrefix}-var-log:/var/log"
    "${volumePrefix}-data:/data"
    "${volumePrefix}-srv:/srv"
    "${volumePrefix}-var-lib-unifi:/var/lib/unifi"
    "${volumePrefix}-var-lib-mongodb:/var/lib/mongodb"
    "${volumePrefix}-etc-rabbitmq-ssl:/etc/rabbitmq/ssl"
  ];

  extraConfig = {
    Container = {
      PidsLimit = "65536";
      AddCapability = "NET_RAW NET_ADMIN";
      PodmanArgs = "--systemd=always";
      HealthCmd = "curl --fail http://127.0.0.1/api/ping || exit 1";
      HealthInterval = "60s";
      HealthTimeout = "5s";
      HealthRetries = "3";
      Network = "pasta:--ns-ifname,eth0,--map-host-loopback,203.0.113.113,--dns-forward,203.0.113.113";
      DNS = "203.0.113.113";
      AddHost = [
        "host.docker.internal:203.0.113.113"
        "host.containers.internal:203.0.113.113"
      ];
      EnvironmentFile = [runtimeEnvFile];
    };
    Unit = {
      After = ["network-online.target"];
      Wants = ["network-online.target"];
    };
    Service = {
      ExecStartPre = [
        "${loadImageScript}/bin/unifi-load-image ${imageRef} ${imagePath}/image.tar"
      ];
      Environment = [
        "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };
}
