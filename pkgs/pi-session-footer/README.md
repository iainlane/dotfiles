# Session footer

A rounded native Pi composer with configurable top and bottom status borders.
Pretty's transcript styling is unchanged. Editing, cursor movement, completion,
history, undo, paste, images and shortcuts remain native. Working, retry and
compaction indicators remain managed by Pi and the installed extensions.

## Configuration

The optional `session-footer.json` lives in Pi's selected agent directory
(`getAgentDir()`), including the temporary app's private directory. Settings are
read at TUI startup and native `/reload`. There are no project overrides,
watchers, environment selectors or settings writes.

```json
{
  "preset": "rich",
  "symbols": { "planning": "≡", "default": "◇" },
  "top-left": [
    "model",
    "thinking",
    "tier",
    "directory",
    "git",
    "git-operation",
    "git-conflicts",
    "pr"
  ],
  "top-right": ["context"],
  "bottom-left": [
    "activity",
    "diagnostics",
    "tasks",
    "blocked",
    "agents",
    "pending",
    "planning",
    "ci",
    "reviews",
    "statuses"
  ],
  "bottom-right": ["quota", "cache", "cost", "auxiliary-cost", "age"]
}
```

- `rich` is the default above.
- `compact` keeps rich's top regions and disables both bottom regions.
- `minimal` keeps directory, Git, operations/conflicts and context at the top.
- `workflow` keeps rich's top and attention fields, with only quota at bottom
  right.

Omitted regions inherit the preset. An explicit array replaces the whole region;
`[]` disables it. IDs are ordered. Repeated IDs within a region are invalid;
intentional repetition across regions is allowed and explained per placement.
Unknown keys, presets and IDs are rejected atomically. An unreadable or invalid
file produces one actionable notification per load and falls back to built-in
rich; `/footer config` retains the diagnostic without exposing file contents.

`symbols` overrides merge with these defaults and are keyed by extension/source
ID. Unknown IDs are supported; `default` is the generic fallback. Symbols must
be nonempty inline strings of at most eight visible columns, without ANSI,
control characters or line breaks. Unicode, Nerd Font glyphs and ASCII such as
`"[P]"` are supported. Invalid symbols reject the entire configuration.
`/footer config` shows effective symbols; `/footer explain` captures the
selected symbols. Passive preset previews retain your symbol overrides.

Optional measurements include `input`, `output`, `cache-read`, `cache-write`,
`run-duration`, `active-duration` and `compaction-duration`. `/footer config`
lists every supported ID and its meaning.

The shared Nix configuration supplies `{ "preset": "rich" }` to normal and
temporary profiles. Override the managed Home Manager asset through Nix, rather
than editing its immutable symlink:

```nix
home.file.".pi/agent/session-footer.json".text = lib.mkForce (builtins.toJSON {
  preset = "compact";
  "top-left" = ["directory" "git" "git-conflicts"];
});
```

## Read-only inspection

Only these command forms exist:

- `/footer` or `/footer explain [segment]`: explain the most recent completed
  render, its timestamp, actual usable widths, ownership and each placement's
  fitting decision. Direct segment explanations include hidden reasons.
- `/footer config`: provenance, effective regions, supported IDs, repeated
  placements and passive preset/JSON previews. Previews never change settings or
  replace the recorded render.
- `/footer help`: grammar, configuration and navigation.

Use the displayed section shortcut (normally `s`) or Tab for the next section.
The native selection, confirm, cancel and page bindings take precedence over
inspector shortcuts. Conflicting `s` or `h` bindings use an advertised Alt
alternative, or omit the shortcut if both are occupied. Confirm expands a field;
cancel returns or closes. The hidden-field shortcut normally uses `h`. Wide
terminals show list and details together; narrow terminals use stacked views.
Paging follows visible list capacity or detail viewport height, with a position
indicator.

The same inspector retains Overview, Quota, Workflow, Diagnostics, Git and Usage
details. These are labelled live data, distinct from captured render readings.
Entering Usage refreshes the existing read-only delegation-cost report; other
views and previews use already observed data. Safe raw delegation JSON remains
available with its truncation limits disclosed. No inspection starts model
calls, quota fetches, diagnostic probes or PR watching. Native `/todos` and
`/subagents` remain available for managing work.

## Display and ownership

Routine detail shortens before actionable warnings. Widening restores full
values. Colours use the active Pi theme; semantic symbols and explicit labels do
not rely on colour alone. The font needs Nerd Font and Powerline glyphs. Missing
placeholders and unavailable readings are hidden; genuine zero measurements are
retained. Initial idle zero cost and age do not create a bottom row. Reported
Git and quota failures remain visible even when their normal readings are
unavailable.

| Symbol                                  | Meaning                                                                                        |
| --------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `` / `` / ``                         | Model / directory / branch                                                                     |
| `⊘` / `○` / `◔` / `◑` / `◒` / `◕` / `◉` | Thinking off / minimal / low / medium / high / xhigh / max                                     |
| `✚` / `✎` / `?` / `↑` / `↓`             | Staged / modified / untracked paths / ahead / behind commits                                   |
| `↻` / `⚠ conflicts`                     | Git operation / conflicting paths                                                              |
| `` / `` / ``                         | Pull request / failed CI checks / unresolved reviews                                           |
| `◫`                                     | Context used percentage and capacity; spare space in its configured row forms a gauge          |
| `☑` / `` / ``                         | Task progress / blocked tasks / active children and independently fitted failed or paused runs |
| `` / `≡` / `◇`                         | Queued messages / planning / actual external source message                                    |
| `⊗` / `⚠`                               | Received errors / warnings; `+` marks lower-bound findings or run counts                       |
| `` / `󰁯` / `` / `✗` / `⊘` / `◷`       | Awaiting input / compaction / current tool / failed / cancelled / no content                   |
| `◴` / `↻`                               | Quota percentage used / reset countdown                                                        |
| `` / `` / ``                         | Latest-request cache hit rate / auxiliary cost / session age                                   |

Thinking shows the actual level with its symbol; compact variants retain the
level symbol. Off is `⊘` alone. Unknown levels retain their reported text.

When neither fitted bottom region has content, the final input row shares the
bottom border. Native hidden input below keeps a separate overflow border. A
populated bottom region adds a dedicated status border without replacing the
editor or losing the draft. Native overflow hints reserve space before fitting.

The composer mounts after extension startup, supporting both Pretty load orders.
It suppresses all standalone footer rows while owning the editor. If another
extension installs an editor later, configured non-empty top and bottom rows
appear below it. The footer never reclaims ownership. Reload, replacement and
shutdown restore the previous editor only while this composer still owns it.
Inspection preserves the draft and returns focus when closed.

## Cooperative extension status

The native `pi.events` protocol has no runtime dependency between extensions:

Producers publish snapshots on `dotfiles:status:v1`:

```typescript
type StatusPublication = {
  version: 1;
  source: string;
  sessionId: string;
  active: boolean;
  text?: string;
};
```

Consumers request a replay on `dotfiles:status:request:v1` with
`{ version: 1, sessionId: string }`.

A producer publishes semantic state on changes and answers requests with its
latest snapshot only when the native session ID matches. It clears publication
and removes its request listener on shutdown. The footer requests snapshots at
session start, accepts subsequent events only for that session, and discards
state/listeners on shutdown. Invalid or wrong-version input is ignored; detail
text is sanitised and bounded. No display labels are parsed for meaning.

Planning publishes source `planning` with its real active flag and no detail by
default: active planning shows only its configured symbol. Optional producer
text follows the symbol; there is no invented implementation phase. Inactive
snapshots hide the status and suppress stale native messages for that source.
Cooperative native keys are excluded from generic duplicates, even when their
dedicated segment is disabled. Other cooperative sources use their configured
symbol or `default`. Older publishers retain readable sanitised native messages,
including their original labels; no prefixes are stripped or guessed. Planning
retains its native `planning` status when used without this footer.

## Measurement scopes

Quota percentages are **used**, not remaining. Readings become stale after 30
seconds and expire after five minutes or reset. `↻` shows reset countdowns, not
reading age. Captured expiry reasons, errors and account/source provenance
remain inspectable even when all percentages are hidden.

Session cost covers recorded branches, summaries, cache warming and reported
tool usage. `$` is provider-billed; `≈$` is a recorded estimate, not a verified
invoice. Auxiliary usage is separate as ``; delegation remains a separate
report and is not summed into session cost. Inline cache rate is the latest
active-branch request. Usage details also show the whole-session denominator;
neither is a claim about invoice savings. Active-work time covers observed
activity only.

Git counts are paths and ahead/behind commits, not changed lines. Directory or
worktree identity appears once. Diagnostics cover received Lens events, not a
workspace-wide verdict. Active child counts are exact fleet totals; incomplete
failed/paused run details can be lower bounds. Missing findings or publications
never establish healthy integrations. Unknown extensions display their actual
sanitised messages with source identity rather than generic counts.

GitHub status comes from [pi-prs]; watching and automatic feedback remain off
unless enabled through its native commands.

[pi-prs]: https://github.com/mavam/pi-prs
