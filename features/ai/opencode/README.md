# OpenCode

Run `opencode` for OpenCode 2 with shared instructions, skills, MCP servers and
language tools.

## Configuration

Nix manages `opencode.json` and `AGENTS.md` under `~/.config/opencode`. Add
settings through `programs.opencode.settings`. Credentials and sessions remain
under `~/.local/share/opencode`.

OpenCode owns `cli.json`, so theme and keybinding changes made in the TUI
persist. On first launch, OpenCode imports the system theme from the managed
`tui.json` if `cli.json` does not exist.

Use `dotfiles.opencode.cliConfig` for CLI settings that should always apply. The
wrapper passes these settings through `OPENCODE_CLI_CONFIG_CONTENT`; OpenCode
does not save the overrides to `cli.json`.

## Herdr integration

The Herdr feature adds its TUI plugin through
`dotfiles.opencode.cliConfig.plugins`. Lists in this option replace the
corresponding lists in `cli.json`. Add other TUI plugins to the Nix option while
the Herdr integration is enabled; plugins listed only in `cli.json` are ignored.
