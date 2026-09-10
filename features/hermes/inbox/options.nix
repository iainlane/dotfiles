{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes.inbox = {
    boardId = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Kanban board which receives inbox work.";
    };
    assignee = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Assignee applied when a proposed card is approved.";
    };
    matrixRoomId = lib.mkOption {
      type = lib.types.str;
      description = "Matrix room which receives inbox digests.";
    };
    matrixUserId = lib.mkOption {
      type = lib.types.str;
      description = "Matrix user authorised to approve or dismiss proposals.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = cfg.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = "Path, relative to the secrets input, containing the AgentMail API key.";
    };
    apiKeySecret = lib.mkOption {
      type = lib.types.str;
      default = "agentmail_api_key";
      description = "Key in secretsFile containing the AgentMail API key.";
    };
    inboxIdSecret = lib.mkOption {
      type = lib.types.str;
      default = "agentmail_inbox_id";
      description = "Key in secretsFile containing the AgentMail inbox ID.";
    };
  };
}
