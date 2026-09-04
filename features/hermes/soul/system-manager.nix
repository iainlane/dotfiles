# The agent's identity file, mounted read-only into every Hermes container by
# `builders.nix`.
{lib, ...}: {
  options.dotfiles.hermes.soul.file = lib.mkOption {
    type = lib.types.path;
    default = ./soul.md;
    description = "Markdown file installed as the agent's SOUL.md identity.";
  };

  config.dotfiles.hermes.soul.present = true;
}
