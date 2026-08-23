{
  adminConfigFile,
  backupPath,
  backupVolume,
  cfg,
  configFile,
  configPath,
  adminConfigPath,
  databasePath,
  image,
  lib,
  package,
  pkgs,
  stateVolume,
}: let
  healthUrl = "http://127.0.0.1:${toString cfg.port}/_matrix/client/versions";
  quadlet = import ../../lib/quadlet.nix {inherit lib;};
in {
  autoStart = true;

  containerConfig = {
    inherit image;

    userns = "auto";

    entrypoint = "${package}/bin/conduwuit";
    exec = "--config ${configPath} --config ${adminConfigPath}";

    volumes =
      quadlet.mounts [
        {
          source.quadletVolume = stateVolume;
          target = databasePath;
          ownership = "idmap";
        }
        {
          source.bind = configFile;
          target = configPath;
          readOnly = true;
        }
        {
          source.bind = adminConfigFile;
          target = adminConfigPath;
          ownership = "idmap";
          readOnly = true;
        }
      ]
      ++ lib.optionals cfg.backup.enable (quadlet.mounts [
        {
          source.quadletVolume = backupVolume;
          target = backupPath;
          ownership = "idmap";
        }
      ]);

    environments.HOME = databasePath;

    dropCapabilities = ["ALL"];
    noNewPrivileges = true;

    # Report ready only once Continuwuity answers, so the proxy and anything
    # else ordered after the homeserver waits for it to be reachable.
    notify = "healthy";
    healthCmd = "${pkgs.curl}/bin/curl -fsS ${healthUrl}";
    healthInterval = "5s";
    healthTimeout = "5s";
    healthRetries = 6;
    healthStartPeriod = "60s";
  };

  unitConfig = {
    Description = "Continuwuity Matrix homeserver";
    After = ["network-online.target" "sops-install-secrets.service"];
    Wants = ["network-online.target" "sops-install-secrets.service"];
  };
}
