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
  };
}
