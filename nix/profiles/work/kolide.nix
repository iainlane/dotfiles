{
  inputs,
  config,
  ...
}: let
  secretsFile = inputs.secrets + "/${config.networking.hostName}/host-crowdstrike-falcon.yaml";
in {
  imports = [
    inputs.kolide-launcher.nixosModules.kolide-launcher
  ];

  services.kolide-launcher.enable = true;

  sops.secrets.kolide = {
    mode = "0600";
    path = "/etc/kolide-k2/secret";
    sopsFile = secretsFile;
  };
}
