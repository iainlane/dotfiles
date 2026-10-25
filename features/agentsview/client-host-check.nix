{
  hostConfig,
  homeConfig,
}: {
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = homeConfig.dotfiles.agentsview;
  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  services =
    if darwin
    then homeConfig.launchd.agents
    else homeConfig.systemd.user.services;
  serviceName =
    if cfg.sync.enable
    then "agentsview-push"
    else "agentsview";
  service = services.${serviceName};
  agentsview = "${inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview}/bin/agentsview";
  environment = {AGENTSVIEW_DATA_DIR = cfg.dataDir;};
  command =
    [agentsview]
    ++ (
      if cfg.sync.enable
      then ["pg" "push" "--watch"]
      else ["serve" "--no-browser" "--port" (toString cfg.port)]
    );
  actual = {
    supervised = lib.filter (name: lib.elem name ["agentsview" "agentsview-push"]) (lib.attrNames services);
    command =
      if darwin
      then service.config.ProgramArguments
      else service.Service.ExecStart;
    environment =
      if darwin
      then service.config.EnvironmentVariables
      else service.Service.Environment;
  };
  expected = {
    supervised = [serviceName];
    command =
      if darwin
      then command
      else [(lib.concatStringsSep " " command)];
    environment =
      if darwin
      then environment
      else lib.mapAttrsToList (name: value: "${name}=${value}") environment;
  };
in {
  "host-evaluation-agentsview-client-${hostConfig.name}" = lib.lazyDerivation {
    derivation = assert lib.assertMsg (actual == expected) "AgentsView client services must allow daemon-backed CLI access without a competing supervised daemon";
      pkgs.runCommandLocal "agentsview-client-startup" {} "touch $out";
    passthru.requiredSystemFeatures = [];
  };
}
