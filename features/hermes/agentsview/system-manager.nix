{
  config,
  hermesBuilders,
  hermesAgentsview,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit (hermesAgentsview) common server;
  identity = hermesAgentsview.pusher;
  passwordPath = inputs.secrets + "/${identity.passwordFile}";
  keyPath = inputs.secrets + "/${cfg.agentsview.secretsFile}";
  keyPresent = (import ../../../lib/sops-keys.nix {inherit lib;}).hasKey keyPath common.privateKeySecret;
  ready = server != null && identity.hasCertificate && builtins.pathExists passwordPath && keyPresent;
  passwordSecret = "hermes_agentsview_password";
  keySecret = "hermes_agentsview_client_key";
  environmentFile = "hermes-agentsview.env";
  stateDirectory = "hermes-agentsview";
  dataDir = "/var/lib/${stateDirectory}";
  agentsview = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agentsview;
  push = pkgs.writeShellApplication {
    name = "hermes-agentsview-push";
    runtimeInputs = [config.virtualisation.podman.package];
    text = ''
      state="$(podman volume inspect --format '{{.Mountpoint}}' ${hermesBuilders.hermesStateVolume})"
      export HERMES_SESSIONS_DIR="$state/.hermes/sessions"
      exec ${agentsview}/bin/agentsview pg push --watch --interval ${toString cfg.agentsview.interval}s
    '';
  };
in {
  config = lib.mkMerge [
    {dotfiles.hermes.agentsview.present = true;}
    (lib.mkIf ready {
      sops = {
        secrets.${passwordSecret} = {
          sopsFile = passwordPath;
          key = common.passwordSecret;
        };
        secrets.${keySecret} = {
          sopsFile = keyPath;
          key = common.privateKeySecret;
          mode = "0400";
        };
        templates.${environmentFile}.content = ''
          AGENTSVIEW_PG_URL=${common.dsn {
            inherit server;
            inherit (identity) machine;
            password = config.sops.placeholder.${passwordSecret};
            certificate = identity.certificatePath;
            key = config.sops.secrets.${keySecret}.path;
          }}
        '';
      };
      systemd.services.hermes-agentsview = {
        description = "Push the Hermes agent's sessions to the shared archive";
        requires = ["sops-install-secrets.service"];
        after = ["network-online.target" "sops-install-secrets.service" "${cfg.container.name}.service"];
        wants = ["network-online.target" "${cfg.container.name}.service"];
        wantedBy = ["system-manager.target"];
        serviceConfig = {
          ExecStart = "${push}/bin/hermes-agentsview-push";
          EnvironmentFile = config.sops.templates.${environmentFile}.path;
          Environment = ["AGENTSVIEW_DATA_DIR=${dataDir}" "AGENTSVIEW_PG_MACHINE=${identity.machine}" "HOME=${dataDir}"];
          StateDirectory = stateDirectory;
          WorkingDirectory = dataDir;
          Restart = "on-failure";
          RestartSec = 30;
        };
      };
    })
  ];
}
