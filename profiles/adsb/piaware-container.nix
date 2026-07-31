{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-piaware
  image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest";
in {
  autoStart = true;

  containerConfig = {
    inherit image;
    networks = [network];
    publishPorts = ["8081:80"];

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

    # The image's own check, reported but never acted on. As well as the
    # connection to FlightAware it counts messages sent in the last hour and
    # calls zero a failure, which a quiet sky produces on its own, so a restart
    # on failure would fire on nothing being overhead.
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
