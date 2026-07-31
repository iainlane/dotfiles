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
