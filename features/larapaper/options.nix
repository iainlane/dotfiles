{
  config,
  hostConfig,
  lib,
  options,
  ...
}: let
  presence = import ../../lib/presence.nix {inherit lib;};
in {
  options.dotfiles.larapaper = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-larapaper.yaml";
      example = "ancaster/host-larapaper.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing the Laravel application key. LaraPaper runs as a system
        service, so this file is encrypted to the host key.
      '';
    };

    appKeyKey = lib.mkOption {
      type = lib.types.str;
      default = "larapaper_app_key";
      description = ''
        Key in `secretsFile` containing the Laravel `APP_KEY`. Laravel
        requires the value to start with `base64:`, followed by 32 random
        bytes encoded with base64.
      '';
    };

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "larapaper";
      description = "Name of the LaraPaper podman container, and the prefix of its backup units.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4567;
      description = ''
        Host port to publish the container's HTTP port on. The container
        listens on 8080 inside. This option also decides the port in
        `appUrl`.
      '';
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = config.dotfiles.network.lanAddress;
      defaultText = lib.literalExpression "config.dotfiles.network.lanAddress";
      example = "192.168.1.138";
      description = ''
        Host address to publish the container's HTTP port on. The default is
        the host's LAN address, so a host that also answers on a routed public
        address does not serve LaraPaper there.
      '';
    };

    appUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${config.dotfiles.larapaper.listenAddress}:${toString config.dotfiles.larapaper.port}";
      defaultText = lib.literalExpression ''"http://''${config.dotfiles.larapaper.listenAddress}:''${toString config.dotfiles.larapaper.port}"'';
      example = "http://192.168.1.138:8080";
      description = ''
        Value of LaraPaper's `APP_URL`. The scheme is required: without it
        LaraPaper renders screen previews and images with the wrong address.
        The default matches the published address, so the TRMNL device and
        LaraPaper use the same URL.
      '';
    };

    backup.present = presence.option "scheduled backups of the database and generated images to Cloudflare R2";
  };

  config.assertions = presence.assertions options [["dotfiles" "larapaper" "backup" "present"]];
}
