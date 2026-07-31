{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/plane-watch/docker-plane-watch
  image = "ghcr.io/plane-watch/docker-plane-watch:latest";
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];

    environments = {
      TZ = "UTC";
      BEASTHOST = "ultrafeeder";
      BEASTPORT = "30005";
    };

    environmentFiles = [envFile];

    # The image's own check, at the image's own timings. It reads connection
    # state: established peers to the beast and MLAT endpoints, and the
    # listening sockets. Losing those is what a restart fixes.
    healthCmd = "bash /scripts/healthcheck.sh";
    healthInterval = "300s";
    healthTimeout = "15s";
    healthStartPeriod = "60s";
    healthRetries = 3;
    healthOnFailure = "restart";

    tmpfses = [
      "/run:exec,size=64M"
      "/var/log:size=32M"
    ];
  };

  unitConfig = {
    Description = "Feed plane.watch";
    After = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
    Wants = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
  };
}
