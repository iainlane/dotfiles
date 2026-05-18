# ccstatusline configuration for Claude Code's status line.
#
# Claude Code dims all status line output (anthropics/claude-code#42382), so
# background colours and powerline segments are invisible. This config uses
# foreground-only ANSI colours with bold text and pipe separators to stay
# readable within that constraint.
{
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
