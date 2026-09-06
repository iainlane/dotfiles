# The UniFi OS controller.
#
# Ubiquiti publish it as a firmware installer rather than a container image, so
# the OCI archive is unpacked out of that installer at build time and loaded
# from the store.
{config, ...}: let
  inherit (config.flake) features;
in {
  imports = [./backup];

  flake.features.unifi = {
    includes = [
      features.containers
      # The controller's ports are published on the host's LAN address, which
      # the network feature derives.
      features.network
      features.unifi.provides.backup
    ];

    systemManager = {
      config,
      lib,
      pkgs,
      quadlet,
      ...
    }: let
      cfg = config.dotfiles.unifi;

      imagePath = pkgs.unifi-os-server-image;

      imageName = "unifi-os";
      network = config.virtualisation.quadlet.networks.unifinet.ref;

      volumes = import ./volumes.nix;

      uuidBuilder = pkgs.writeShellApplication {
        name = "unifi-build-uuid-env";
        runtimeInputs = with pkgs; [coreutils util-linux gnugrep];
        text = builtins.readFile ./build-uuid-env.sh;
      };

      unifiContainer = import ./container.nix {
        inherit cfg network quadlet volumes;
        inherit (imagePath) firmwarePlatform;
        serverVersion = imagePath.version;
        image = config.virtualisation.quadlet.images.${imageName}.ref;
        uuidBuilder = "${uuidBuilder}/bin/unifi-build-uuid-env";
      };
    in {
      imports = [./options.nix];

      config = {
        virtualisation.quadlet = {
          networks.unifinet = {};

          volumes = lib.genAttrs (map (mount: mount.volume) volumes.all) (_: {});

          images.${imageName}.imageConfig = {
            image = "docker-archive:${imagePath}/image.tar";
            tag = "localhost/${imagePath.imageTag}";
          };

          containers.unifi-os = unifiContainer;
        };
      };
    };
  };
}
