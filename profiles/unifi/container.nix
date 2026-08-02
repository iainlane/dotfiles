{
  cfg,
  image,
  network,
  uuidBuilder,
}: let
  volumePrefix = "unifi";
  runtimeDirectory = "unifi";
  runtimeEnvFile = "/run/${runtimeDirectory}/runtime.env";

  defaultPorts = [
    "${toString cfg.webPort}:443"
    "5005:5005"
    "5671:5671"
    "6789:6789"
    "8080:8080"
    "8444:8444"
    "8880:8880"
    "8881:8881"
    "8882:8882"
    "9543:9543"
    "28082:28082"
    "3478:3478/udp"
    "5514:5514/udp"
    "10001:10001/udp"
    "10003:10003/udp"
  ];
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];
    publishPorts = defaultPorts ++ cfg.extraPorts;

    # UniFi OS runs its own init, which wants to manage more processes than
    # podman's default allows, and raw sockets for device discovery.
    pidsLimit = 65536;
    addCapabilities = ["NET_RAW" "NET_ADMIN"];
    podmanArgs = ["--systemd=always"];

    healthCmd = "curl --fail http://127.0.0.1/api/ping || exit 1";
    healthInterval = "60s";
    healthTimeout = "5s";
    healthRetries = 3;

    environments = {
      APP_MODEL = "UOSSERVER";
      APP_VERSION = cfg.serverVersion;
      PRODUCT_NAME = "uosserver";
      FIRMWARE_PLATFORM = cfg.firmwarePlatform;
    };

    environmentFiles = [runtimeEnvFile];

    volumes = [
      "${volumePrefix}-persistent:/persistent"
      "${volumePrefix}-var-log:/var/log"
      "${volumePrefix}-data:/data"
      "${volumePrefix}-srv:/srv"
      "${volumePrefix}-var-lib-unifi:/var/lib/unifi"
      "${volumePrefix}-var-lib-mongodb:/var/lib/mongodb"
      "${volumePrefix}-etc-rabbitmq-ssl:/etc/rabbitmq/ssl"
    ];
  };

  unitConfig = {
    Description = "UniFi OS Server";
    After = ["network-online.target"];
    Wants = ["network-online.target"];
  };

  serviceConfig = {
    RuntimeDirectory = runtimeDirectory;
    ExecStartPre = ["${uuidBuilder}"];
  };
}
