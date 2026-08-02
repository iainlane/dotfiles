{lib, ...}: {
  options.services.unifi = {
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 11443;
      description = "HTTPS web UI port for UniFi OS.";
    };

    extraPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["1900:1900/udp"];
      description = "Additional port mappings beyond the defaults.";
    };

    serverVersion = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = "Version of the UniFi OS release the image was taken from.";
    };

    firmwarePlatform = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = "Platform name UniFi OS expects for this architecture.";
    };
  };
}
