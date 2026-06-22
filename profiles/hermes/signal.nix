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
  inherit
    (import ./builders.nix {inherit config inputs lib pkgs;})
    mkNixImage
    hermesUser
    hermesUserNS
    hermesNss
    hermesCacheVolume
    hardeningPodmanArgs
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
  signalImageRef = "localhost/${cfg.signal.containerName}:${signalImage.imageTag}";
  signalImageUnit = "podman-${cfg.signal.containerName}-image.service";
in {
  config = lib.mkIf (cfg.enable && cfg.signal.enable) {
    home.packages = [signalCliPackage];

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

    services.podman = {
      volumes.${signalStateVolume} = {
        description = "signal-cli account state";
      };

      networks.${cfg.signal.network} = {
        description = "Hermes and signal-cli network";
        extraConfig.Service.Environment = {
          PATH = "/usr/local/libexec/podman:/run/wrappers/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        };
      };

      images.${cfg.signal.containerName} = {
        image = "docker-archive:${signalImage}";
        autoStart = true;
      };

      containers.${cfg.signal.containerName} = {
        autoStart = true;
        description = "signal-cli JSON-RPC daemon for Hermes";
        image = signalImageRef;
        user = hermesUser;
        userNS = hermesUserNS;
        entrypoint = "${signalCliPackage}/bin/signal-cli";
        exec = "--config /data daemon --http 0.0.0.0:8080";
        network = ["${cfg.signal.network}.network"];
        volumes =
          [
            "${signalStateVolume}.volume:/data"
            # Hermes writes outgoing attachments under /data/.hermes/cache in
            # its own namespace and hands signal-cli that path, so the shared
            # cache volume resolves them to the same files here.
            "${hermesCacheVolume}.volume:/data/.hermes/cache:ro"
          ]
          ++ lib.optional (cfg.profilePicture != null) "${cfg.profilePicture}:${profilePictureContainerPath}:ro";
        environment.HOME = "/data";
        dropCapabilities = ["ALL"];
        extraPodmanArgs = hardeningPodmanArgs;
        extraConfig = {
          Unit = {
            After = ["network-online.target" signalImageUnit];
            Wants = ["network-online.target" signalImageUnit];
          };
          Service = {
            Environment = [
              "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
            ];
          };
        };
      };
    };
  };
}
