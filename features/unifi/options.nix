{lib, ...}: {
  options.dotfiles.unifi = {
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 11443;
      description = ''
        Port on the host's LAN address the HTTPS web UI is published on. The
        controller serves it on 443 inside the container.
      '';
    };

    extraPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["1900:1900/udp"];
      description = ''
        Port mappings published in addition to the ones the controller always
        needs. Each is passed to podman as written, so a mapping that should
        stay off the routed public address has to name the LAN address
        itself.
      '';
    };
  };
}
