# Codex

Run `codex` with shared instructions, MCP servers and language tools.

## Configuration

Nix writes shared defaults and MCP servers to `/etc/codex/config.toml`. User
settings in `~/.codex/config.toml` and project settings in `.codex/config.toml`
can override these defaults.

Add hooks through `dotfiles.codex.hooks`. Hook groups for the same event are
combined, so additional hooks do not replace the shared prose-lint or Herdr
hooks.
