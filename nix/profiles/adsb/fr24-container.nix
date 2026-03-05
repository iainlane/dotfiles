{envFile}: let
  # renovate: datasource=docker depName=ghcr.io/sdr-enthusiasts/docker-flightradar24
  image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest";
in {
  autoStart = true;
  description = "Feed FlightRadar24";
  inherit image;
  network = "adsbnet.network";
  ports = ["8754:8754"];

  environment = {
    BEASTHOST = "ultrafeeder";
    BEASTPORT = "30005";
    MLAT = "no";
  };

  extraConfig = {
    Container = {
      EnvironmentFile = [envFile];
      Tmpfs = ["/var/log:size=32M"];
    };
    Service = {
      Environment = [
        "PATH=/usr/local/libexec/podman:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
    Unit = {
      After = [
        "network-online.target"
        "podman-ultrafeeder.service"
        "sops-nix.service"
      ];
      Wants = [
        "network-online.target"
        "podman-ultrafeeder.service"
        "sops-nix.service"
      ];
    };
  };
}
