# The prose-lint hooks, in the hook format that Claude Code and Codex share.
# Codex matches its `apply_patch` tool with the `Edit` and `Write` matchers.
{
  lib,
  pkgs,
}: let
  hook = event: matcher:
    {
      hooks = [
        {
          type = "command";
          command = "${lib.getExe pkgs.prose-lint} hook ${event}";
          timeout = 30;
        }
      ];
    }
    // lib.optionalAttrs (matcher != null) {inherit matcher;};
in {
  PostToolUse = [(hook "post-tool-use" "Edit|Write|MultiEdit")];
  PreToolUse = [(hook "pre-tool-use" "Bash|Edit|Write|MultiEdit")];
  Stop = [(hook "stop" null)];
}
