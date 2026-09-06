{
  config,
  lib,
  ...
}: {
  options.dotfiles.unifi = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = config.dotfiles.network.lanAddress;
      defaultText = lib.literalExpression "config.dotfiles.network.lanAddress";
      example = "0.0.0.0";
      description = ''
        Host address the controller's ports are published on. The default is
        the host's LAN address, so a host that also answers on a routed public
        address keeps the admin UI, the unencrypted inform port, RabbitMQ and
        syslog off the internet.
      '';
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 11443;
      description = ''
        Port on `listenAddress` the HTTPS web UI is published on. The
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
        stay off the routed public address has to write out `listenAddress`
        itself.
      '';
    };
  };
}
