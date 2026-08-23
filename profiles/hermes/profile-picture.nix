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
  quadlet = import ../../lib/quadlet.nix {inherit lib;};
  inherit
    (import ./builders.nix {inherit config inputs lib pkgs;})
    mkNixImage
    hermesUser
    hermesNss
    hardening
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
  profilePictureImageUnit = "${profilePictureContainerName}-image.service";
  profilePictureEnvFiles =
    lib.optionals cfg.matrix.enable [config.sops.templates."hermes-matrix.env".path]
    ++ lib.optionals cfg.signal.enable [config.sops.templates."hermes-signal.env".path];
  profilePictureNetworks =
    lib.toList cfg.container.network
    ++ lib.optional cfg.signal.enable "${cfg.signal.network}.network";
in {
  config = lib.mkIf (cfg.enable && cfg.profilePicture != null && (cfg.matrix.enable || cfg.signal.enable)) {
    virtualisation.quadlet = {
      volumes.${profilePictureStateVolume} = {};

      images.${profilePictureContainerName}.imageConfig = {
        image = "docker-archive:${profilePictureImage}";
        tag = "localhost/${profilePictureContainerName}:${profilePictureImage.imageTag}";
      };

      containers.${profilePictureContainerName} = {
        # Run by the timer below, not at activation.
        autoStart = false;

        containerConfig =
          hardening
          // {
            image = config.virtualisation.quadlet.images.${profilePictureContainerName}.ref;
            user = hermesUser;
            entrypoint = "${profilePictureScript}/bin/hermes-profile-picture";
            networks = profilePictureNetworks;
            volumes = quadlet.mounts [
              {
                source.quadletVolume = profilePictureStateVolume;
                target = "/state";
              }
              {
                source.bind = cfg.profilePicture;
                target = profilePictureContainerPath;
                readOnly = true;
              }
            ];
            environments =
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
            environmentFiles = profilePictureEnvFiles;
          };

        unitConfig = {
          Description = "Hermes messaging profile picture rotation";
          After =
            ["network-online.target" "sops-install-secrets.service" profilePictureImageUnit]
            ++ lib.optional cfg.signal.enable "${cfg.signal.containerName}.service";
          Wants =
            ["network-online.target" "sops-install-secrets.service" profilePictureImageUnit]
            ++ lib.optional cfg.signal.enable "${cfg.signal.containerName}.service";
        };

        serviceConfig.Restart = "no";
      };
    };

    systemd.timers.hermes-profile-picture = {
      description = "Rotate the Hermes messaging profile picture hourly";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnUnitActiveSec = "1h";
        OnBootSec = "10m";
        Unit = "${profilePictureContainerName}.service";
      };
    };
  };
}
