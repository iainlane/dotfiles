# The UniFi OS controller.
#
# Ubiquiti publish it as a firmware installer rather than a container image, so
# the OCI archive is unpacked out of that installer at build time and loaded
# from the store.
{
  flake.profiles.unifi = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.systemManagerModule = args: {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.unifi;
      sources = lib.importJSON ./sources.json;
      platform =
        sources.platforms.${pkgs.stdenv.hostPlatform.system}
        or (throw "unifi: unsupported system ${pkgs.stdenv.hostPlatform.system}");

      # The installer ships an OCI archive inside its own firmware image, which
      # is unpacked at build time and loaded through a quadlet.
      imagePath = import ./image.nix {
        inherit pkgs;
        src = pkgs.fetchurl {inherit (platform) url hash;};
        inherit (sources) version;
      };

      imageName = "unifi-os";
      network = config.virtualisation.quadlet.networks.unifinet.ref;

      uuidBuilder = pkgs.writeShellApplication {
        name = "unifi-build-uuid-env";
        runtimeInputs = with pkgs; [coreutils util-linux gnugrep];
        text = builtins.readFile ./build-uuid-env.sh;
      };

      unifiContainer = import ./container.nix {
        inherit cfg network;
        image = config.virtualisation.quadlet.images.${imageName}.ref;
        uuidBuilder = "${uuidBuilder}/bin/unifi-build-uuid-env";
      };
    in {
      imports = [./options.nix];

      config = lib.mkMerge [
        {
          services.unifi =
            args
            // {
              serverVersion = sources.version;
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
              tag = "localhost/${sources.imageTag}";
            };

            containers.unifi-os = unifiContainer;
          };
        }
      ];
    };
  };
}
