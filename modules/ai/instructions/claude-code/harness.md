# Claude Code Harness

Guidance specific to the Claude Code harness.

## Waiting for background work

- The harness waits for tools natively. Do not write `sleep` or `while` polling
  loops to watch for a background process exiting. Instead:
  - Run long commands with the `Bash` tool's `run_in_background` option. You are
    notified automatically when the command exits.
  - Use `TaskOutput` with `block: true` to wait for a running task to finish.
  - Use `Monitor` to stream events from a long-running process, such as watching
    a log file for errors or readiness markers.

## Command output

- Run commands bare and read their full output. Never pipe through `tail`,
  `head`, `grep -m` or similar to shorten what the tool returns. This applies
  to every `Bash` call, foreground or background, and regardless of your
  reason: even when you believe that you only need part of the output. The pipe
  stops the user from watching the command's output live, and it can hide errors
  and cause wasted re-runs.
- The harness handles long output. Foreground output is truncated safely, and
  background task output is written to a file whose path is returned in the
  tool result and in the completion notification. Read it with `Read` or
  search it with `Grep` afterwards.
- If you genuinely need a bounded result, use the command's own flags
  (`git log -5`, `journalctl -n 50`) rather than a pipe.
