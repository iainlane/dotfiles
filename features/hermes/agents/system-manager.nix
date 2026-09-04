# The agent's operating instructions, mounted read-only into its workspace by
# `builders.nix`.
{lib, ...}: {
  options.dotfiles.hermes.agents.file = lib.mkOption {
    type = lib.types.path;
    default = ./agents.md;
    description = ''
      Markdown file installed as AGENTS.md in the agent's working
      directory, loaded as workspace context alongside SOUL.md.
    '';
  };

  config.dotfiles.hermes.agents.present = true;
}
