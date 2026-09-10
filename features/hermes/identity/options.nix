{
  config,
  lib,
  ...
}: let
  cfg = config.dotfiles.hermes;
in {
  options.dotfiles.hermes = {
    identity = {
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Name to use for the agent's Git commits.";
      };
      email = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Email address to use for the agent's Git commits.";
      };
      secretsFile = lib.mkOption {
        type = lib.types.str;
        default = cfg.secretsFile;
        defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
        description = "Path, relative to the `secrets` input, of the sops file containing the SSH private key.";
      };
      secretKey = lib.mkOption {
        type = lib.types.str;
        default = "ssh_private_key";
        description = "Key in `identity.secretsFile` containing the agent's SSH private key.";
      };
      sign = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether Git signs the agent's commits and tags with its SSH key.";
      };
    };
  };
}
