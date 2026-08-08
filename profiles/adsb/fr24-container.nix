{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-flightradar24 versioning=docker
  tag = "latest";
  image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:${tag}";
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];
    publishPorts = ["8754:8754"];

    environments = {
      BEASTHOST = "ultrafeeder";
      BEASTPORT = "30005";
      MLAT = "no";
    };

    environmentFiles = [envFile];

    # The image's own check: a connection to the feed source, the status site
    # listening, and no service deaths. It empties /var/log/fr24feed.log each
    # time it runs, so the interval is also how much log is kept; upstream's
    # ten minutes is what the image is built around.
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
