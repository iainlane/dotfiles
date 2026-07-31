{
  envFile,
  network,
  ultrafeederService,
}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-flightradar24
  image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest";
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

    tmpfses = ["/var/log:size=32M"];
  };

  unitConfig = {
    Description = "Feed FlightRadar24";
    After = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
    Wants = ["network-online.target" "sops-install-secrets.service" ultrafeederService];
  };
}
