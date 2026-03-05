{envFile}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-piaware
  image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest";
in {
  autoStart = true;
  description = "Feed FlightAware (piaware)";
  inherit image;
  network = "adsbnet.network";
  ports = ["8081:80"];

  environment = {
    TZ = "UTC";
    RECEIVER_TYPE = "relay";
    BEASTHOST = "ultrafeeder";
    BEASTPORT = "30005";
    MLAT_RESULTS_BEASTHOST = "ultrafeeder";
    MLAT_RESULTS_BEASTPORT = "31004";
    ALLOW_MLAT = "yes";
    MLAT_RESULTS = "yes";
  };

  extraConfig = {
    Container = {
      EnvironmentFile = [envFile];
      Tmpfs = [
        "/run:exec,size=64M"
        "/var/log:size=32M"
      ];
    };
    Service = {
      Environment = [
        "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
    Unit = {
      After = [
        "network-online.target"
        "sops-nix.service"
        "podman-ultrafeeder.service"
      ];
      Wants = [
        "network-online.target"
        "sops-nix.service"
        "podman-ultrafeeder.service"
      ];
    };
  };
}
