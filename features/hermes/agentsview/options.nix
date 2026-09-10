{
  config,
  lib,
  ...
}: {
  options.dotfiles.hermes.agentsview = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = config.dotfiles.hermes.secretsFile;
      defaultText = lib.literalExpression "config.dotfiles.hermes.secretsFile";
      description = "Path, relative to the `secrets` input, of the sops file containing the AgentsView client key.";
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Seconds the AgentsView watcher waits between scans.";
    };
  };
}
