# Profile picture rotation for messaging platforms. A short-lived helper
# container joins the same private networks as the platform sidecars, selects an
# image, and updates every enabled platform from there.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;
  inherit
    (import ./builders.nix {inherit config inputs lib pkgs;})
    mkNixImage
    hermesUser
    hermesUserNS
    hermesNss
    hardeningPodmanArgs
    profilePictureContainerPath
    ;

  profilePictureContainerName = "hermes-profile-picture";
  profilePictureStateVolume = "hermes-profile-picture-state";
  profilePictureScript = pkgs.writeShellApplication {
    name = "hermes-profile-picture";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      file
      findutils
      jq
    ];
    text = builtins.readFile ./profile-picture.sh;
  };
  profilePictureImage = mkNixImage profilePictureContainerName [
    profilePictureScript
    pkgs.coreutils
    pkgs.curl
    pkgs.file
    pkgs.findutils
    pkgs.jq
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    hermesNss
  ];
  profilePictureImageRef = "localhost/${profilePictureContainerName}:${profilePictureImage.imageTag}";
  profilePictureImageUnit = "podman-${profilePictureContainerName}-image.service";
  profilePictureEnvFiles =
    lib.optionals cfg.matrix.enable [config.sops.templates."hermes-matrix.env".path]
    ++ lib.optionals cfg.signal.enable [config.sops.templates."hermes-signal.env".path];
  profilePictureNetworks =
    lib.toList cfg.container.network
    ++ lib.optional cfg.matrix.enable "${cfg.matrix.network}.network"
    ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";
in {
  config = lib.mkIf (cfg.enable && cfg.profilePicture != null && (cfg.matrix.enable || cfg.signal.enable)) {
    services.podman = {
      volumes.${profilePictureStateVolume} = {
        description = "Hermes profile picture rotation state";
      };

      images.${profilePictureContainerName} = {
        image = "docker-archive:${profilePictureImage}";
        autoStart = true;
      };

      containers.${profilePictureContainerName} = {
        autoStart = true;
        description = "Hermes messaging profile picture rotation";
        image = profilePictureImageRef;
        user = hermesUser;
        userNS = hermesUserNS;
        entrypoint = "${profilePictureScript}/bin/hermes-profile-picture";
        network = profilePictureNetworks;
        volumes = [
          "${profilePictureStateVolume}.volume:/state"
          "${cfg.profilePicture}:${profilePictureContainerPath}:ro"
        ];
        environment =
          {
            PROFILE_PICTURE_SOURCE = profilePictureContainerPath;
            PROFILE_PICTURE_STATE_DIR = "/state";
          }
          // lib.optionalAttrs cfg.matrix.enable {
            MATRIX_PROFILE_PICTURE_ENABLED = "true";
            MATRIX_HOMESERVER = cfg.matrix.httpUrl;
            MATRIX_USER_ID = "@${cfg.matrix.username}:${cfg.matrix.serverName}";
          }
          // lib.optionalAttrs (cfg.matrix.enable && cfg.matrix.displayName != null) {
            MATRIX_DISPLAY_NAME = cfg.matrix.displayName;
          }
          // lib.optionalAttrs cfg.signal.enable {
            SIGNAL_PROFILE_PICTURE_ENABLED = "true";
            SIGNAL_HTTP_URL = cfg.signal.httpUrl;
          };
        environmentFile = profilePictureEnvFiles;
        dropCapabilities = ["ALL"];
        extraPodmanArgs = hardeningPodmanArgs;
        extraConfig = {
          Unit = {
            After =
              ["network-online.target" "sops-nix.service" profilePictureImageUnit]
              ++ lib.optional cfg.matrix.enable "podman-${cfg.matrix.containerName}.service"
              ++ lib.optional cfg.signal.enable "podman-${cfg.signal.containerName}.service";
            Wants =
              ["network-online.target" "sops-nix.service" profilePictureImageUnit]
              ++ lib.optional cfg.matrix.enable "podman-${cfg.matrix.containerName}.service"
              ++ lib.optional cfg.signal.enable "podman-${cfg.signal.containerName}.service";
          };
          Service = {
            Environment = [
              "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
            ];
            Restart = "no";
          };
        };
      };
    };

    systemd.user.timers.hermes-profile-picture = {
      Unit.Description = "Rotate the Hermes messaging profile picture hourly";
      Timer = {
        OnUnitActiveSec = "1h";
        Unit = "podman-${profilePictureContainerName}.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
