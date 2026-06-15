# ccstatusline configuration for Claude Code's status line.
#
# Claude Code dims all status line output (anthropics/claude-code#42382), so
# background colours and powerline segments are invisible. This config uses
# foreground-only ANSI colours with bold text and pipe separators to stay
# readable within that constraint.
#
# `extraUsageCommand` is the path to a helper that prints month-to-date
# extra-usage spend; it backs the custom-command widget below.
{extraUsageCommand}: {
  version = 3;
  colorLevel = 1;
  globalBold = true;
  defaultSeparator = "|";

  lines = [
    [
      {
        id = "model";
        type = "model";
        color = "cyan";
        rawValue = true;
      }
      {
        id = "git-branch";
        type = "git-branch";
        color = "magenta";
      }
      {
        id = "git-changes";
        type = "git-changes";
        color = "yellow";
      }
      {
        id = "flex";
        type = "flex-separator";
      }
      {
        id = "context-pct";
        type = "context-percentage";
        color = "green";
      }
      {
        id = "session-cost";
        type = "session-cost";
        color = "yellow";
      }
      # Weekly rolling-limit usage (Pro/Max). Hidden on accounts without a
      # weekly cap, such as enterprise seats.
      {
        id = "weekly-usage";
        type = "weekly-usage";
        color = "green";
        metadata.hideWhenEmpty = "true";
      }
      # Month-to-date extra-usage spend. Always shown when extra usage is
      # enabled, including uncapped accounts where no limit is set.
      {
        id = "extra-usage-spend";
        type = "custom-command";
        color = "yellow";
        commandPath = extraUsageCommand;
        timeout = 1000;
        metadata.hideWhenEmpty = "true";
      }
      # Remaining extra-usage budget. Renders only when a monthly limit
      # applies; hidden otherwise.
      {
        id = "extra-usage-remaining";
        type = "extra-usage-remaining";
        color = "yellow";
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

  flexMode = "full-minus-40";
  compactThreshold = 60;
  inheritSeparatorColors = false;

  powerline = {
    enabled = false;
  };
}
