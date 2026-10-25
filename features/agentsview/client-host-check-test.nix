{
  lib,
  pkgs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  nixbuild = import ../../lib/nixbuild.nix {inherit lib;};
  check = homeConfig:
    (import ./client-host-check.nix {
        hostConfig.name = "fixture";
        inherit homeConfig;
      } {
        inherit lib pkgs;
        inputs.llm-agents.packages.${system}.agentsview = "/agentsview";
      }).host-evaluation-agentsview-client-fixture;
  unavailable = check (throw "AgentsView check metadata forced the host configuration");
  fixture = syncing: let
    serviceName =
      if syncing
      then "agentsview-push"
      else "agentsview";
    command =
      if syncing
      then ["/agentsview/bin/agentsview" "pg" "push" "--watch"]
      else ["/agentsview/bin/agentsview" "serve" "--no-browser" "--port" "8080"];
    environment = {AGENTSVIEW_DATA_DIR = "/archive";};
  in {
    dotfiles.agentsview = {
      sync.enable = syncing;
      dataDir = "/archive";
      port = 8080;
    };
    launchd.agents.${serviceName}.config = {
      ProgramArguments = command;
      EnvironmentVariables = environment;
    };
    systemd.user.services.${serviceName}.Service = {
      ExecStart = [(lib.concatStringsSep " " command)];
      Environment = ["AGENTSVIEW_DATA_DIR=/archive"];
    };
  };
  startup = syncing: let
    homeConfig = fixture syncing;
    serviceName =
      if syncing
      then "agentsview-push"
      else "agentsview";
    invalid = lib.recursiveUpdate homeConfig (
      if darwin
      then {launchd.agents.${serviceName}.config.EnvironmentVariables.AGENTSVIEW_NO_DAEMON = "1";}
      else {systemd.user.services.${serviceName}.Service.Environment = ["AGENTSVIEW_DATA_DIR=/archive" "AGENTSVIEW_NO_DAEMON=1"];}
    );
  in {
    valid = (check homeConfig).drvPath != "";
    invalidRejected = !(builtins.tryEval (check invalid).drvPath).success;
  };
  actual = {
    metadata = {
      derivation = lib.isDerivation unavailable;
      requiredSystemFeatures = nixbuild.requiredFeatures unavailable;
      runOnce = unavailable.ci.runOnce or false;
    };
    unavailableRejected = !(builtins.tryEval unavailable.drvPath).success;
    startup = map startup [false true];
  };
  expected = {
    metadata = {
      derivation = true;
      requiredSystemFeatures = [];
      runOnce = false;
    };
    unavailableRejected = true;
    startup = lib.replicate 2 {
      valid = true;
      invalidRejected = true;
    };
  };
in {
  agentsview-client-check =
    pkgs.runCommandLocal "agentsview-client-check" {
      actual = builtins.toJSON actual;
      expected = builtins.toJSON expected;
    } ''
      if [ "$actual" != "$expected" ]; then
        printf 'Expected: %s\nActual: %s\n' "$expected" "$actual" >&2
        exit 1
      fi
      touch "$out"
    '';
}
