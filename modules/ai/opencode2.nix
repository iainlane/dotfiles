# Configure OpenCode 2 with the shared MCP servers, instructions and skills.
#
# OpenCode 2 defaults to the same `~/.config/opencode` as OpenCode 1, but the
# two config schemas are not interchangeable and a single `programs.opencode`
# can only generate one of them. `OPENCODE_CONFIG_DIR` moves OpenCode 2 to its
# own directory, which this module owns. Credentials and session storage stay
# under `~/.local/share/opencode`, so one login covers both versions.
#
# `cli.json` (theme, keybindings) is deliberately not managed here: OpenCode 2
# rewrites that file itself whenever the theme or a setting changes in the TUI.
# To still get a theme on a fresh machine, `tui.json` below is seeded and
# OpenCode 2's v1 migration folds it into `cli.json` on first launch.
{
  config,
  inputs,
  lib,
  mcp,
  skillTree,
  pkgs,
  system,
  ...
}: let
  instructions = import ./agent-instructions.nix {inherit lib;};

  jsonFormat = pkgs.formats.json {};

  configDir = "opencode2";

  # OpenCode 2's schema: servers live under `mcp.servers`, a local server's
  # command and args are a single list, `env` becomes `environment`, and
  # `enabled` is replaced by `disabled`.
  mkMcpServer = server:
    {disabled = server.disabled or false;}
    // (
      if server ? url
      then
        {
          type = "remote";
          inherit (server) url;
        }
        // lib.optionalAttrs (server ? headers) {inherit (server) headers;}
      else
        {
          type = "local";
          command = [server.command] ++ (server.args or []);
        }
        // lib.optionalAttrs (server ? env) {environment = server.env;}
    );

  settings = {
    "$schema" = "https://opencode.ai/config.json";

    # Updates come from Nix, not opencode's self-updater.
    autoupdate = false;

    mcp.servers = lib.mapAttrs (_name: mkMcpServer) config.dotfiles.ai.mcpServers;
  };

  # OpenCode 2 keeps theme and keybindings in `cli.json` and owns that file at
  # runtime, so it cannot be written from here. It does read a v1-shaped
  # `tui.json` once, when `cli.json` is still absent, and translates it: this
  # `theme` arrives as `theme.name`. Editing this later has no effect, because
  # the migration only runs while `cli.json` does not exist. Values OpenCode 1
  # left in `~/.local/state/opencode/kv.json` are merged in at the same time.
  tui = {
    theme = "system";
  };

  wrappedOpencode2 = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.opencode2;
    binName = "opencode2";
    extraWrapperArgs = [
      "--set"
      "OPENCODE_CONFIG_DIR"
      "${config.xdg.configHome}/${configDir}"
    ];
  };
in {
  home.packages = [wrappedOpencode2];

  xdg.configFile = {
    "${configDir}/opencode.json".source =
      jsonFormat.generate "opencode.json" settings;

    "${configDir}/tui.json".source =
      jsonFormat.generate "tui.json" tui;

    "${configDir}/AGENTS.md".text = instructions.concatenated;

    # OpenCode 2 discovers everything under `<config dir>/skills` without
    # being told about it.
    "${configDir}/skills" = {
      source = skillTree config.dotfiles.ai.skills;
      recursive = true;
    };
  };
}
