{
  config,
  inputs,
  ...
}: let
  secretsFile = inputs.secrets + "/${config.networking.hostName}/host-crowdstrike-falcon.yaml";
  falconRelease = import (inputs.secrets + "/crowdstrike/falcon.nix");
in {
  services.falcon-sensor = {
    enable = true;
    cidFile = config.sops.secrets.falcon-cid.path;
    release = falconRelease;
    traceLevel = "err";
  };

  sops.secrets = {
    falcon-cid = {
      mode = "0600";
      sopsFile = secretsFile;
    };
  };
}
