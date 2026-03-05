{envFile}: let
  # renovate: datasource=docker depName=ghcr.io/plane-watch/docker-plane-watch
  image = "ghcr.io/plane-watch/docker-plane-watch:latest";
in {
  autoStart = true;
  description = "Feed plane.watch";
  inherit image;
  network = "adsbnet.network";

  environment = {
    TZ = "UTC";
    BEASTHOST = "ultrafeeder";
    BEASTPORT = "30005";
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
