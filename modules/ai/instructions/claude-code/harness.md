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

## Do not truncate command output

- Do not pipe commands through `tail`, `head` or similar just to keep the output
  short. It hides information from you and stops the user from watching the
  output live.
- Long output is not a problem. Background task output is written to a file
  whose path is returned in the tool result and in the completion notification.
  Read it with `Read` or search it with `Grep` afterwards.
