# Shared option declaration and base value for Claude Code's managed
# settings. Keeps the policy data in one place; the OS-specific placement
# modules import this and add the file-placement step appropriate to the
# target (environment.etc vs. /Library symlink).
#
# The policy itself is exposed as the option
# `dotfiles.claudeCode.managedSettings`. Other modules may contribute
# additional keys (e.g. `permissions.deny` lists); definitions are merged by
# concatenating and deduplicating the `permissions.{deny,ask,allow}` lists
# and recursively updating everything else.
{
  lib,
  pkgs,
  inputs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (inputs.llm-agents.packages.${system}) ccstatusline;

  # Replace Claude Code's built-in `@` file picker with `fd | fzf --filter` so
  # queries get real fuzzy scoring and untracked files appear. See
  # ./file-suggestion for the rationale.
  fileSuggestionCommand = pkgs.callPackage ./file-suggestion {};

  # Fields named here are merged as sets — their lists are concatenated and
  # deduplicated, first occurrence winning for ordering. Every other field
  # follows recursive update: objects deep-merge, scalar leaves are replaced.
  setMergedPaths.permissions = lib.genAttrs ["deny" "ask" "allow"] (_: true);

  mergeSettings = let
    walk = paths: l: r: let
      setMerged =
        lib.mapAttrs (
          key: sub:
            if builtins.isAttrs sub
            then walk sub (l.${key} or {}) (r.${key} or {})
            else lib.unique ((l.${key} or []) ++ (r.${key} or []))
        )
        paths;
    in
      lib.filterAttrs (_: v: v != [] && v != {})
      (lib.recursiveUpdate l r // setMerged);
  in
    walk setMergedPaths;

  mergeSettingsList = builtins.foldl' mergeSettings {};
in {
  options.dotfiles.claudeCode.managedSettings = lib.mkOption {
    type = lib.mkOptionType {
      name = "claude-code-managed-settings";
      description = "Claude Code managed-settings.json policy";
      check = builtins.isAttrs;
      merge = _loc: defs:
        mergeSettingsList (map (d: d.value) defs);
    };
    default = {};
    description = ''
      Contents of Claude Code's system-wide managed-settings.json policy.
      Other modules may contribute to this attrset; definitions are merged
      by concatenating and deduplicating the `permissions.{deny,ask,allow}`
      lists and recursively updating everything else.
    '';
  };

  # Sort this last so that the config here _overrides_ any incoming systemwide
  # config.
  config.dotfiles.claudeCode.managedSettings = lib.mkAfter {
    allowManagedPermissionRulesOnly = false;
    alwaysThinkingEnabled = true;
    attribution = {
      commit = "";
      pr = "";
    };
    enabledPlugins = {
      "claude-code-setup@claude-plugins-official" = true;
      "claude-md-management@claude-plugins-official" = true;
      "code-review@claude-plugins-official" = true;
      "feature-dev@claude-plugins-official" = true;
      "frontend-design@claude-plugins-official" = true;
      "pr-review-toolkit@claude-plugins-official" = true;
      "ralph-loop@claude-plugins-official" = true;
      "security-guidance@claude-plugins-official" = true;
      # It seems to aggressively replace default behaviours.
      # "superpowers@claude-plugins-official" = true;
      "typescript-lsp@claude-plugins-official" = true;
    };
    env = {
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
    };
    extraKnownMarketplaces = {
      "anthropic-agent-skills" = {
        source = {
          source = "github";
          repo = "anthropics/skills";
        };
      };
    };
    fileSuggestion = {
      type = "command";
      command = lib.getExe fileSuggestionCommand;
    };
    model = "claude-fable-5[1m]";
    skipDangerousModePermissionPrompt = true;
    statusLine = {
      type = "command";
      command = "${ccstatusline}/bin/ccstatusline";
      padding = 0;
    };
    tui = "fullscreen";
    voiceEnabled = true;
  };
}
