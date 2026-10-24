# Session footer

A two-row view of the current Pi session. The footer keeps the model, project,
context usage and quota visible while attention indicators show pending input,
failed work, diagnostics, tasks and subagents.

The rows adapt to terminal width. Routine details disappear before failures and
other attention indicators. Widen the terminal to restore the full display.
Colours follow the active Pi theme; labels distinguish warnings without relying
on colour. The terminal font needs Powerline glyphs.

## Inspecting a session

Run `/footer` to choose a detail view, or open one directly:

- `/footer quota`: used allowance, reset times, freshness and the account that
  supplied the reading.
- `/footer workflow`: tasks, dependencies, subagent runs and planning status.
- `/footer diagnostics`: received findings and their coverage.
- `/footer git`: worktree state, pull request, reviews and CI.
- `/footer usage`: costs, cache rates and activity times.
- `/footer overview`: model, context and extension statuses.

Use the arrow and page keys to scroll, and Escape to close. Inspection does not
start a model turn. The native `/todos` and `/subagents` commands remain
available for managing work.

## Interpreting the display

Quota is used allowance. A reading becomes stale after 30 seconds and expires
after five minutes or its reset time. Missing and expired readings show
`unavailable`. A countdown does not fetch a new reading.

Session cost includes recorded branches, summaries, cache warming and reported
tool usage. Auxiliary calls, including `/btw`, appear separately as `aux`.
Delegation has a separate accounting scope in the inspector. These are recorded
estimates, not invoices.

Session age starts at the session header. Active-work time excludes waits for
input and covers activity observed since the footer loaded.

Diagnostics cover received Lens events, not the whole workspace. An absent
finding does not establish that a file is clean or that a server is healthy.
GitHub status comes from [pi-prs]; watching and automatic feedback remain off
unless enabled through its commands.

[pi-prs]: https://github.com/mavam/pi-prs
