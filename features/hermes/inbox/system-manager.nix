{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;
  inherit (cfg) inbox;
  package = pkgs.hermes-inbox;
  pythonPackages = import ../../../lib/hermes-python.nix {inherit inputs lib pkgs;};
  inherit (import ../../../lib/sops-keys.nix {inherit lib;}) hasKey;
  secretsPath = inputs.secrets + "/${inbox.secretsFile}";
  inboxSecretsAvailable = lib.all (hasKey secretsPath) [
    inbox.apiKeySecret
    inbox.inboxIdSecret
  ];
  webhookSecretsPath = inputs.secrets + "/${cfg.webhook.secretsFile}";
  webhookSecretAvailable = hasKey webhookSecretsPath cfg.webhook.secretKey;
  routeScript = "${package}/${pythonPackages.python.sitePackages}/hermes_inbox/route_script.py";
in {
  config = lib.mkMerge [
    {
      dotfiles.hermes = {
        inbox.present = true;
        webhook.secretKey = lib.mkDefault "agentmail_webhook_secret";
      };
    }
    (lib.mkIf (inboxSecretsAvailable && webhookSecretAvailable) {
      dotfiles.hermes = {
        extraPlugins.hermes-inbox = "${package}/share/hermes-inbox-plugin";
        extraPythonPackages = [
          package
          pkgs.agentmail
          pythonPackages.beautifulsoup4
          pythonPackages.markdownify
          pythonPackages.soupsieve
        ];
        container.extraVolumes = [
          {
            source.bind = routeScript;
            target = "/data/.hermes/scripts/hermes-inbox.py";
            readOnly = true;
          }
        ];
        environmentFiles = [config.sops.templates."hermes-inbox.env".path];
        settings = {
          auxiliary.hermes_inbox_classification.model = lib.mkDefault cfg.smallModel;
          kanban.auto_decompose = false;
          plugins = {
            enabled = ["hermes-inbox"];
            entries.hermes-inbox = {
              enabled = true;
              settings = {
                inbox_id = "\${HERMES_INBOX_ID}";
                board_id = inbox.boardId;
                inherit (inbox) assignee;
                matrix_room_id = inbox.matrixRoomId;
                matrix_user_id = inbox.matrixUserId;
              };
            };
          };
          platforms.webhook.extra.routes.agentmail = {
            events = ["message.received"];
            script = "/data/.hermes/scripts/hermes-inbox.py";
            prompt = "AgentMail intake failed to suppress direct webhook delivery.";
            deliver = "matrix";
            deliver_only = true;
            deliver_extra.chat_id = inbox.matrixRoomId;
          };
        };
      };

      sops = {
        secrets = {
          ${inbox.apiKeySecret}.sopsFile = secretsPath;
          ${inbox.inboxIdSecret}.sopsFile = secretsPath;
        };
        templates."hermes-inbox.env".content = ''
          AGENTMAIL_API_KEY=${config.sops.placeholder.${inbox.apiKeySecret}}
          HERMES_INBOX_ID=${config.sops.placeholder.${inbox.inboxIdSecret}}
        '';
      };
    })
  ];
}
