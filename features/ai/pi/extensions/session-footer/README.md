# Session footer

A fixed, two-row footer for this configuration. It replaces pi-footer without
replacing Pi's editor or adding tools to the model.

The first row identifies the model, thinking level, project, Git branch and
worktree, with context usage on the right. Service-tier bolts appear beside the
thinking level, for example `high ⚡⚡`. The second row combines conditional
attention and workflow indicators with used quota, reset countdowns, estimated
cost and live session age. Thin Powerline separators point towards the centre:
`` between left-hand groups and `` before each right-aligned item. Right-hand
items remain aligned when there are no attention indicators. Home directories
are abbreviated to `~`, and `` identifies the branch. The terminal font must
include Powerline glyphs.

Each row fits independently. Under width pressure, quota countdowns disappear
before age and cost, then routine labels become shorter or disappear. Quota
percentages can disappear before failures and other attention indicators. Equal
priorities preserve display order, including the provider's quota-window order.

`+N` counts fully omitted items from either side of a row, not shortened labels
or removed countdowns. A compact `…` replaces the count when space is limited.
At positive widths the footer keeps two rows; very narrow rows truncate their
highest-priority remaining item, and an omission marker may not fit. Widening
restores full values.

## Colours

The [palette] defines theme roles, bold emphasis and state-dependent colour
rules. Colours follow the active Pi theme, including custom and Catppuccin
themes, and update on redraw without `/reload`.

| Field                                              | Theme style                             |
| -------------------------------------------------- | --------------------------------------- |
| Model                                              | Bold `accent`                           |
| Directory                                          | Bold `mdCode`                           |
| Thinking level                                     | Corresponding `thinking*` colour        |
| Fresh quota and normal context values              | `toolTitle`                             |
| Task and agent counts                              | `mdLink`                                |
| Git branch: clean / dirty / conflicting / stale    | `success` / `warning` / `error` / `dim` |
| Staged / unstaged Git counts                       | `success` / `warning`                   |
| Plan, routine activity and PR identity             | `accent`                                |
| Service-tier bolts                                 | `warning` (yellow in Catppuccin)        |
| Labels and provider                                | `muted`                                 |
| Supporting detail, cost and age                    | `dim`                                   |
| Separators                                         | `border`                                |
| Errors / warnings, including stale or cached quota | `error` / `warning`                     |

Context values use `warning` from 75% and `error` from 90%. Freshness labels and
attention text remain explicit, so colour is not the only signal.

[palette]: src/palette.ts

## Details

Run `/footer` to choose a read-only detail view, or open one directly:

- `/footer quota`: used percentages, freshness, reading account/source and
  linear-window pace where an exact duration is available.
- `/footer workflow`: task dependencies, subagent runs, plan state and pending
  messages.
- `/footer diagnostics`: received findings and their coverage limitations.
- `/footer git`: worktree, operation, PR, reviews and CI.
- `/footer usage`: accounting scope, cache rates and distinct timers.
- `/footer overview`: model, context and other extension statuses.

Use the arrow and page keys to scroll, and Escape to close. The inspector does
not dispatch commands or start model turns. The native `/todos`, `/subagents`
and `/lens-widget-toggle` commands remain available.

## Data semantics

Quota percentages describe used allowance. Readings become stale after 30
seconds, and numerical usage expires after five minutes or its reset time.
Cached and stale readings are labelled explicitly. Expired or missing readings
show `unavailable`. Countdown updates do not fetch quota. Account identity
belongs to the reading; the footer does not inspect credentials or assume that a
fallback credential matches the model runtime. Malformed same-provider updates
retain the previous reading with an explicit error and its original expiry.
Provider changes and explicit unavailable states clear old data.

Session cost includes all recorded branches, summaries, cache warming and
reported tool usage. It is an estimate, not an invoice. Delegation reports have
their own scope and are not added to that figure. Session age starts at the
session header; observed active-work time excludes waits for user input and
covers only activity observed since this footer loaded.

Diagnostic counts cover received pi-lens events, not the whole workspace.
Touched files remain provisional until a new diagnostic snapshot arrives. An
absent event does not establish a clean file or healthy server.

[pi-prs] owns GitHub polling. This footer consumes its public state client.
Watching and automatic feedback delivery remain off unless explicitly enabled
through pi-prs commands. The Pi launcher supplies `gh` on its inherited PATH for
these queries; agent shell commands inherit that PATH too.

Git and subagent failures retain bounded error reasons in the inspector. Failed
Git and status refreshes mark previous data stale; a later successful read
clears the error. A non-repository directory is not a Git failure. The
task-widget visibility flag is read once per overlay instance, so changes
require `/reload`; its existing height and shortcut-label settings still read
live configuration.

[pi-prs]: https://github.com/mavam/pi-prs

## Development

Use Node 24, npm, Git and Python 3:

```sh
npm ci --ignore-scripts
npm run check
```

Tests copy pinned upstream packages into the ignored `.fixtures/` directory and
apply this repository's quota-metadata and task-widget patches. Network fixtures
use MSW. Real-TUI tests launch the pinned Pi CLI in a PTY with an isolated home,
synthetic data and the built-in light and dark themes. They cover quiet and
active sessions, live theme changes, repeated quota updates, resizing from 220
to 72 columns and back, and inspector paging and Escape. HTTP requests are
blocked and logged; an unexpected model turn also fails the test. The Nix
`pi-session-footer` check runs the same checks without network or real
credentials.
