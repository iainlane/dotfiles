# The Signal platform: a signal-cli JSON-RPC daemon sidecar the agent reaches
# over a private podman network, plus the secrets and env that point it there.
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
    hermesCacheVolume
    hardening
    profilePictureContainerPath
    ;

  signalStateVolume = "signal-state";
  signalCliPackage =
    if cfg.signal.package != null
    then cfg.signal.package
    else pkgs.signal-cli;
  signalSecretsFile = inputs.secrets + "/${cfg.signal.secretsFile}";
  signalImage = mkNixImage cfg.signal.containerName [
    signalCliPackage
    pkgs.coreutils
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    hermesNss
  ];
  signalImageUnit = "${cfg.signal.containerName}-image.service";
in {
  config = lib.mkIf (cfg.enable && cfg.signal.enable) {
    environment.systemPackages = [signalCliPackage];

    sops = {
      secrets = {
        signal_account.sopsFile = signalSecretsFile;
        signal_allowed_users.sopsFile = signalSecretsFile;
        signal_home_channel.sopsFile = signalSecretsFile;
      };

      templates."hermes-signal.env".content = ''
        SIGNAL_ACCOUNT=${config.sops.placeholder.signal_account}
        SIGNAL_ALLOWED_USERS=${config.sops.placeholder.signal_allowed_users}
        SIGNAL_HOME_CHANNEL=${config.sops.placeholder.signal_home_channel}
      '';
    };

    services.hermes-agent = {
      environment.SIGNAL_HTTP_URL = cfg.signal.httpUrl;
      environmentFiles = [config.sops.templates."hermes-signal.env".path];
    };

    virtualisation.quadlet = {
      volumes.${signalStateVolume} = {};

      networks.${cfg.signal.network} = {};

      images.${cfg.signal.containerName}.imageConfig = {
        image = "docker-archive:${signalImage}";
        tag = "localhost/${cfg.signal.containerName}:${signalImage.imageTag}";
      };

      containers.${cfg.signal.containerName} = {
        autoStart = true;

        containerConfig =
          hardening
          // {
            image = config.virtualisation.quadlet.images.${cfg.signal.containerName}.ref;
            user = hermesUser;
            entrypoint = "${signalCliPackage}/bin/signal-cli";
            exec = "--config /data daemon --http 0.0.0.0:8080";
            networks = ["${cfg.signal.network}.network"];
            volumes =
              quadlet.mounts [
                {
                  source.quadletVolume = signalStateVolume;
                  target = "/data";
                }
                # Hermes writes outgoing attachments under /data/.hermes/cache in
                # its own namespace and hands signal-cli that path, so the shared
                # cache volume resolves them to the same files here.
                {
                  source.quadletVolume = hermesCacheVolume;
                  target = "/data/.hermes/cache";
                  readOnly = true;
                }
              ]
              ++ lib.optionals (cfg.profilePicture != null) (quadlet.mounts [
                {
                  source.bind = cfg.profilePicture;
                  target = profilePictureContainerPath;
                  readOnly = true;
                }
              ]);
            environments.HOME = "/data";
          };

        unitConfig = {
          Description = "signal-cli JSON-RPC daemon for Hermes";
          After = ["network-online.target" signalImageUnit];
          Wants = ["network-online.target" signalImageUnit];
        };
      };
    };
  };
}
