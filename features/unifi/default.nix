# The UniFi OS controller.
#
# Ubiquiti publish it as a firmware installer rather than a container image, so
# the OCI archive is unpacked out of that installer at build time and loaded
# from the store.
{config, ...}: {
  flake.features.unifi = {
    includes = [config.flake.features.containers];

    systemManager = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.unifi;

      # The installer ships an OCI archive inside its own firmware image, which
      # the package unpacks at build time and a quadlet loads from the store.
      imagePath = pkgs.unifi-os-server-image;

      imageName = "unifi-os";
      network = config.virtualisation.quadlet.networks.unifinet.ref;

      uuidBuilder = pkgs.writeShellApplication {
        name = "unifi-build-uuid-env";
        runtimeInputs = with pkgs; [coreutils util-linux gnugrep];
        text = builtins.readFile ./build-uuid-env.sh;
      };

      unifiContainer = import ./container.nix {
        inherit cfg lib network;
        image = config.virtualisation.quadlet.images.${imageName}.ref;
        uuidBuilder = "${uuidBuilder}/bin/unifi-build-uuid-env";
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          services.unifi = {
            serverVersion = imagePath.version;
            firmwarePlatform =
              if pkgs.stdenv.hostPlatform.isAarch64
              then "linux-arm64"
              else "linux-x64";
          };
        }
        {
          virtualisation.quadlet = {
            networks.unifinet = {};

            images.${imageName}.imageConfig = {
              image = "docker-archive:${imagePath}/image.tar";
              tag = "localhost/${imagePath.imageTag}";
            };

            containers.unifi-os = unifiContainer;
          };
        }
      ];
    };
  };
}
