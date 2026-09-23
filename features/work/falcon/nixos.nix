{
  config,
  inputs,
  ...
}: let
  secretsFile = inputs.secrets + "/${config.networking.hostName}/host-crowdstrike-falcon.yaml";
  cacheSecretsFile = inputs.secrets + "/crowdstrike/cache.yaml";
  cachePassword = "falcon-cache-password";
in {
  services.falcon-sensor = {
    enable = true;
    cidFile = config.sops.secrets.falcon-cid.path;
    traceLevel = "err";
  };

  dotfiles.nix.binaryCaches."cupboard.supply/t/laney/cache/falcon" = {
    publicKeys = ["cupboard-laney-2:qpgAuXaVoxE7uPvqcNdSdQgRTtVl8L3nxf0NeO/cQfo="];
  };

  nix.settings.netrc-file = config.sops.templates."falcon-cache.netrc".path;

  sops.secrets = {
    falcon-cid = {
      mode = "0600";
      sopsFile = secretsFile;
    };
    ${cachePassword} = {
      key = "password";
      mode = "0400";
      restartUnits = ["nix-daemon.service"];
      sopsFile = cacheSecretsFile;
    };
  };

  sops.templates."falcon-cache.netrc" = {
    mode = "0400";
    content = ''
      machine cupboard.supply
      login cupboard
      password ${config.sops.placeholder.${cachePassword}}
    '';
  };
}
