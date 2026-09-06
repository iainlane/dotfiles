# Claude Code Harness

Guidance specific to the Claude Code harness.

## Waiting for Background Work

- The harness waits for tools natively. Do not write `sleep` or `while` polling
  loops to watch for a background process exiting. Instead:
  - Run long commands with the `Bash` tool's `run_in_background` option. You are
    notified automatically when the command exits.
  - Use `TaskOutput` with `block: true` to wait for a running task to finish.
  - Use `Monitor` to stream events from a long-running process, such as watching
    a log file for errors or readiness markers.

## Command Output

- Run commands bare and read their full output. Never truncate it: no `tail`,
  `head`, `grep -m` or similar to cut a command's output down to a length you
  find comfortable. This applies to every `Bash` call, foreground or background,
  and regardless of your reason: even when you believe that you only need part
  of the output. Truncation hides errors and causes wasted re-runs. Searching a
  large file for the lines you want, with `grep` or `rg`, is a different thing
  and is fine.
- The user's terminal shows at most a few lines of a command's output. If the
  user needs to read any of it, put it in your reply.
- The harness handles long output. Foreground output is truncated safely, and
  background task output is written to a file whose path is returned in the tool
  result and in the completion notification. Read it with `Read` or search it
  with `Grep` afterwards.
- If you genuinely need a bounded result, use the command's own flags
  (`git log -5`, `journalctl -n 50`) rather than a pipe.
