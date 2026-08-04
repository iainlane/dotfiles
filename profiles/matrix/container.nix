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
  networks,
  package,
  pkgs,
  stateVolume,
}: let
  healthUrl = "http://127.0.0.1:${toString cfg.port}/_matrix/client/versions";
in {
  autoStart = true;

  containerConfig = {
    inherit image networks;

    userns = "auto";

    entrypoint = "${package}/bin/conduwuit";
    exec = "--config ${configPath} --config ${adminConfigPath}";

    volumes =
      [
        "${stateVolume}.volume:${databasePath}"
        "${configFile}:${configPath}:ro"
        "${adminConfigFile}:${adminConfigPath}:ro,idmap"
      ]
      ++ lib.optional cfg.backup.enable "${backupVolume}.volume:${backupPath}";

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
