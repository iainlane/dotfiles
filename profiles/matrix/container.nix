{
  adminConfigFile,
  cfg,
  configFile,
  configPath,
  adminConfigPath,
  databasePath,
  image,
  networks,
  package,
  pkgs,
  stateVolume,
}: let
  healthUrl = "http://127.0.0.1:${toString cfg.port}/_matrix/client/versions";

  # Presents a mount's contents as owned by the homeserver, so files root owns
  # on the host are readable inside without host root being mapped in.
  asService = "idmap=uids=@0-${toString cfg.uid}-1;gids=@0-${toString cfg.gid}-1";
in {
  autoStart = true;

  containerConfig = {
    inherit image networks;

    userns = "auto";
    user = toString cfg.uid;
    group = toString cfg.gid;

    entrypoint = "${package}/bin/conduwuit";
    exec = "--config ${configPath} --config ${adminConfigPath}";

    volumes = [
      "${stateVolume}.volume:${databasePath}:${asService}"
      "${configFile}:${configPath}:ro"
      "${adminConfigFile}:${adminConfigPath}:ro,${asService}"
    ];

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
