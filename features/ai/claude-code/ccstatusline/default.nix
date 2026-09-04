# ccstatusline configuration for Claude Code's status line.
#
# Claude Code dims all status line output (anthropics/claude-code#42382), so
# background colours and powerline segments are invisible. This config uses
# foreground-only ANSI colours with bold text and pipe separators to stay
# readable within that constraint.
#
# The custom-command widgets are backed by the small helpers built below, each
# reading the status-line JSON on stdin, the usage API, or local git state. See
# the matching .sh files for their logic.
{
  pkgs,
  lib,
}: let
  # extra-usage fetches the usage API itself; curl for the request, coreutils
  # for date/stat/mktemp. On macOS it reads the token from the Keychain via the
  # system `security` binary (kept on PATH), elsewhere from the credentials file.
  extraUsage = pkgs.writeShellApplication {
    name = "ccstatusline-extra-usage";

    runtimeInputs = with pkgs; [
      jq
      gawk
      curl
      coreutils
    ];

    text = builtins.readFile ./extra-usage.sh;
  };

  worktree = pkgs.writeShellApplication {
    name = "ccstatusline-worktree";

    runtimeInputs = with pkgs; [
      jq
      git
      coreutils
    ];

    text = builtins.readFile ./worktree.sh;
  };

  gitAheadBehind = pkgs.writeShellApplication {
    name = "ccstatusline-git-ahead-behind";

    runtimeInputs = with pkgs; [
      jq
      git
      coreutils
    ];

    text = builtins.readFile ./git-ahead-behind.sh;
  };

  usagePct = pkgs.writeShellApplication {
    name = "ccstatusline-usage-pct";

    runtimeInputs = with pkgs; [
      jq
      gawk
      coreutils
    ];

    text = builtins.readFile ./usage-pct.sh;
  };

  extraUsageCommand = lib.getExe extraUsage;
  worktreeCommand = lib.getExe worktree;
  aheadBehindCommand = lib.getExe gitAheadBehind;
  usagePctCommand = lib.getExe usagePct;
in {
  version = 3;
  colorLevel = 1;
  globalBold = true;
  defaultSeparator = "|";

  lines = [
    # ccstatusline has no width-based priority: when the line overflows it
    # truncates from the right, so widgets are ordered left-to-right by
    # importance. `hideWhenEmpty` drops widgets that have nothing to show
    # (clean tree, enterprise account without subscription limits), which
    # does most of the contextual trimming.
    [
      {
        id = "model";
        type = "model";
        color = "cyan";
        rawValue = true;
      }

      {
        id = "thinking-effort";
        type = "thinking-effort";
        color = "blue";
        rawValue = true;
      }

      # Git group: branch · worktree · changes · ahead-behind, joined into one
      # cluster set off from the rest by a single "|". ccstatusline has no
      # per-widget separator, and `merge` suppresses the separator after a
      # widget (merging it with the next), so every git widget sets merge to
      # drop the "|", and merged " · " custom-text widgets supply a light
      # separator. The worktree and ahead-behind come from helpers that print
      # their own leading separator and collapse to nothing when they have
      # nothing to show, so they leave no dangling separator. git-changes always
      # renders, so its separator is a plain custom-text widget.
      {
        id = "git-branch";
        type = "git-branch";
        color = "magenta";
        merge = true;
      }

      {
        id = "git-worktree";
        type = "custom-command";
        color = "magenta";
        commandPath = worktreeCommand;
        timeout = 1000;
        merge = true;
        metadata.hideWhenEmpty = "true";
      }

      {
        id = "git-sep-changes";
        type = "custom-text";
        customText = " · ";
        color = "brightBlack";
        merge = true;
      }

      {
        id = "git-changes";
        type = "git-changes";
        color = "yellow";
        merge = true;
      }

      {
        id = "git-ahead-behind";
        type = "custom-command";
        color = "magenta";
        commandPath = aheadBehindCommand;
        timeout = 1000;
        merge = true;
        metadata.hideWhenEmpty = "true";
      }

      {
        id = "flex";
        type = "flex-separator";
      }

      # Context used against the usable window (before auto-compaction).
      # rawValue drops the "Ctx(u) Used:" label, leaving just the percentage.
      {
        id = "context-usable";
        type = "context-percentage-usable";
        color = "green";
        rawValue = true;
      }

      # Five-hour and weekly rolling-limit usage (Pro/Max), read from the
      # rate_limits block Claude Code provides on stdin. A plan without a given
      # window omits its bucket, so the helper emits nothing and the widget
      # hides via hideWhenEmpty.
      {
        id = "session-usage";
        type = "custom-command";
        color = "green";
        commandPath = "${usagePctCommand} five_hour 5h";
        timeout = 1000;
        metadata.hideWhenEmpty = "true";
      }

      {
        id = "weekly-usage";
        type = "custom-command";
        color = "green";
        commandPath = "${usagePctCommand} seven_day wk";
        timeout = 1000;
        metadata.hideWhenEmpty = "true";
      }

      {
        id = "session-cost";
        type = "session-cost";
        color = "yellow";
      }

      # Month-to-date extra-usage spend. This figure is absent from the stdin
      # JSON, so its helper fetches the usage API directly and emits nothing on
      # error or while rate-limited, so the widget hides via hideWhenEmpty.
      {
        id = "extra-usage-spend";
        type = "custom-command";
        color = "yellow";
        commandPath = extraUsageCommand;
        timeout = 1000;
        metadata.hideWhenEmpty = "true";
      }

      {
        id = "session-clock";
        type = "session-clock";
        color = "brightBlack";
      }
    ]

    []
    []
  ];

  flexMode = "full";
  compactThreshold = 60;
  inheritSeparatorColors = false;

  powerline = {
    enabled = false;
  };
}
