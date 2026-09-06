{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-piaware versioning=docker
  tag = "latest@sha256:086f48dfbb31d7551e40c0d3d57a6b4727eb54aa184e5c438ca57151740e299c";
  image = "ghcr.io/sdr-enthusiasts/docker-piaware:${tag}";
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];

    environments = {
      TZ = "UTC";
      RECEIVER_TYPE = "relay";
      BEASTHOST = "ultrafeeder";
      BEASTPORT = "30005";
      MLAT_RESULTS_BEASTHOST = "ultrafeeder";
      MLAT_RESULTS_BEASTPORT = "31004";
      ALLOW_MLAT = "yes";
      MLAT_RESULTS = "yes";
    };

    environmentFiles = [envFile];

    # The image's own check tests the connection to FlightAware and fails if
    # no messages were sent in the last hour. An hour with no aircraft
    # overhead therefore fails the check even when the feeder is working.
    # Report the result without restarting the container.
    healthCmd = "/scripts/healthcheck.sh";
    healthInterval = "600s";
    healthStartPeriod = "7200s";

    tmpfses = [
      "/run:exec,size=64M"
      "/var/log:size=32M"
    ];
  };

  unitConfig = {
    Description = "Feed FlightAware (piaware)";
    After = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
    Wants = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
  };
}
