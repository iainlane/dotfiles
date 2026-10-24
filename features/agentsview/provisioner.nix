{topology}: {
  lib,
  pkgs,
  ...
}: let
  plan = (import ./provisioning-plan.nix {inherit lib;}) topology;
  planFile = pkgs.writeText "agentsview-provisioning.json" (builtins.toJSON plan);
  program = pkgs.writeShellApplication {
    name = "generate-agentsview-secrets";
    runtimeInputs = with pkgs; [coreutils findutils gnugrep jq openssl sops yq-go];
    text = ''
      export AGENTSVIEW_PROVISIONING_PLAN=${planFile}
      export AGENTSVIEW_COMMON_LIBRARY=${../../scripts/lib/just-common.bash}
      exec ${pkgs.bash}/bin/bash ${../../scripts/generate-agentsview-secrets.bash} "$@"
    '';
  };
in {
  generate-agentsview-secrets = {
    type = "app";
    program = lib.getExe program;
    meta.description = "Generate the declared AgentsView credentials in a secrets checkout";
  };
}
