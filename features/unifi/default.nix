# The UniFi OS controller.
#
# Ubiquiti publish UniFi OS Server as a firmware installer with an embedded
# OCI archive. Extract the archive at build time and load it from the store.
{config, ...}: let
  inherit (config.dotfiles) features;
in {
  imports = [./backup];

  dotfiles.flakeSystem.includes = [features.unifi];

  dotfiles.features.unifi = {
    checks = [./checks.nix];

    includes = [
      features.containers
      # The controller's ports are published on the host's LAN address, which
      # the network feature derives.
      features.network
      features.unifi.backup
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
        text = builtins.readFile ./build-uuid-env.bash;
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

          volumes = lib.genAttrs (map (mount: mount.volume) volumes) (_: {});

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
