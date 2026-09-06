{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-flightradar24 versioning=docker
  tag = "latest@sha256:917e53402d5158800eef746839dfb722e30cd3b21019e3bc318abb4f3d807c03";
  image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:${tag}";
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];

    environments = {
      BEASTHOST = "ultrafeeder";
      BEASTPORT = "30005";
      MLAT = "no";
    };

    environmentFiles = [envFile];

    # The image's own check: a connection to the feed source, the status site
    # listening, and no service deaths. It truncates /var/log/fr24feed.log each
    # time it runs, so the interval also decides how much log is kept. Ten
    # minutes is the value upstream builds the image around.
    healthCmd = "/scripts/healthcheck.sh";
    healthInterval = "600s";
    healthStartPeriod = "600s";
    healthOnFailure = "restart";

    tmpfses = ["/var/log:size=32M"];
  };

  unitConfig = {
    Description = "Feed FlightRadar24";
    After = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
    Wants = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
  };
}
