{
  cfg,
  firmwarePlatform,
  image,
  lanAddress,
  network,
  quadlet,
  serverVersion,
  uuidBuilder,
  volumes,
}: let
  runtimeDirectory = "unifi";
  runtimeEnvFile = "/run/${runtimeDirectory}/runtime.env";

  # The controller's own ports, published on the host's LAN address. This host
  # also holds a routed public address, so a publish that named every address
  # would put the admin UI, the unencrypted inform port, RabbitMQ and syslog in
  # front of the internet.
  publish = mapping: "${lanAddress}:${mapping}";

  defaultPorts = map publish [
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

    healthCmd = "curl --fail http://127.0.0.1/api/ping";
    healthInterval = "60s";
    healthTimeout = "5s";
    healthRetries = 3;

    environments = {
      APP_MODEL = "UOSSERVER";
      APP_VERSION = serverVersion;
      PRODUCT_NAME = "uosserver";
      FIRMWARE_PLATFORM = firmwarePlatform;
    };

    environmentFiles = [runtimeEnvFile];

    volumes = quadlet.mounts (
      map (mount: {
        source.quadletVolume = mount.volume;
        inherit (mount) target;
      })
      volumes.all
    );
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
