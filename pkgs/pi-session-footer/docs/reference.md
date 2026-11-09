# Configuration and measurements

Use `/footer config` for live editing, or edit the base document and run Pi's
native `/reload`. The base is `<getAgentDir()>/session-footer.json`. Local
preferences, when present, are in the sibling `session-footer.user.json`.

## Documents and profiles

The `preset` key selects `rich`, `compact`, `minimal` or `workflow`; omission
selects `rich`. The UI calls these profiles.

```json
{
  "preset": "rich",
  "top-left": ["model", "thinking", "directory", "git"],
  "top-right": ["context"],
  "bottom-left": [],
  "bottom-right": ["cache", "cost", "age"]
}
```

Region arrays replace a whole region. Omitted regions inherit the profile; `[]`
disables a region. Arrays preserve display order. A widget may appear in several
regions, with independent appearance and fitting. Duplicate IDs within one
region are invalid, including a string and an object with the same ID.

Choosing a profile over custom rows asks whether to replace those rows or keep
them with a different base profile. The resulting draft is not saved until the
main save action.

### Available widgets

| IDs                                                      | Meaning                                                                 |
| -------------------------------------------------------- | ----------------------------------------------------------------------- |
| `model`, `thinking`, `tier`                              | Selected model, reasoning level and published service tier.             |
| `directory`                                              | Directory or worktree identity.                                         |
| `git`, `git-operation`, `git-conflicts`                  | Branch, file counts, ahead/behind commits, operation and conflicts.     |
| `pr`, `ci`, `reviews`                                    | Published pull request, failed checks and unresolved review threads.    |
| `context`                                                | Context used and capacity; spare row space can display a gauge.         |
| `activity`                                               | Current tool, waiting, compaction, failure, cancellation or inactivity. |
| `diagnostics`                                            | Received error and warning counts.                                      |
| `tasks`, `blocked`, `agents`                             | Task progress, dependency-blocked tasks and child agents.               |
| `pending`, `planning`, `statuses`                        | Queued messages, cooperative planning and extension messages.           |
| `quota`                                                  | Quota used and reset countdowns.                                        |
| `cache`, `cost`, `auxiliary-cost`, `age`                 | Cache hit rate, session cost, separate auxiliary cost and session age.  |
| `input`, `output`, `cache-read`, `cache-write`           | Recorded token totals.                                                  |
| `run-duration`, `active-duration`, `compaction-duration` | Current run, observed active work and current compaction time.          |

Missing readings are hidden. Genuine zero measurements remain visible, except
initial idle cost and age. A populated bottom region adds a dedicated status
border; otherwise the final input row shares the bottom border. Native overflow
indicators reserve their space before footer fitting.

## Placement appearance

A string uses default appearance. An object accepts `id`, `colour`, `symbol` and
`roles`:

```json
{
  "top-left": [
    "model",
    {
      "id": "git",
      "colour": "text",
      "symbol": { "alias": "git", "colour": "accent" },
      "roles": {
        "staged": {
          "colour": "text",
          "symbol": { "text": "+", "colour": "success" }
        }
      }
    }
  ],
  "bottom-right": ["git", "cache", "cost"]
}
```

The bottom-right Git placement is unchanged. Editing an inherited placement
materialises only its region. Resetting appearance removes its overrides; an
otherwise empty object becomes its string ID again.

`colour` affects ordinary text. `symbol.colour` affects its marker
independently. Explicit role settings override the applicable placement
settings. Ordinary placement colours preserve warning, error and stale styling.
A role override can change that styling deliberately, without changing the state
label or attention priority.

### Symbol forms

| Value of `symbol`                        | Meaning                                 |
| ---------------------------------------- | --------------------------------------- |
| `""`                                    | Literal symbol.                         |
| `"git"`                                  | Literal text `git`.                     |
| `{ "text": "[G]", "colour": "accent" }`  | Literal text with its own colour.       |
| `{ "alias": "git" }`                     | Built-in Git symbol.                    |
| `{ "alias": "git", "colour": "accent" }` | Alias with its own colour.              |
| `{ "colour": "accent" }`                 | Default symbol with a different colour. |

`text` and `alias` are mutually exclusive. An empty object has no override. A
literal object without colour can become its string value when saved; an alias
remains an object. Resetting the symbol value and resetting its colour are
independent operations.

Symbols must be nonempty safe inline text, with no leading or trailing
whitespace, ANSI, controls, format characters or line breaks. The limit is eight
terminal columns and 64 UTF-16 code units. Gauge symbols require exactly one
column. The built-in catalogue uses the existing footer symbols and real state
symbols; the UI lists the available aliases.

Colour values are supported foreground theme tokens, such as `accent`, `text`,
`muted`, `success`, `warning` and `error`, or strict `#RRGGBB` strings. Theme
tokens follow theme changes. Saved values never contain ANSI sequences.

### Individual parts

The UI exposes only controls supported by each part. Plain-text parts have no
symbol control; symbol-only parts have no text-colour control.

| Widget                           | Supported role IDs                                                               |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `model`                          | `model`, `provider`                                                              |
| `thinking`                       | `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`                        |
| `git`                            | `branch`, `staged`, `modified`, `untracked`, `ahead`, `behind`, `stale`, `error` |
| `git-operation`, `git-conflicts` | `operation`; `error`, respectively                                               |
| `pr`                             | `number`, `blocked`, `conflicting`, `unavailable`                                |
| `context`                        | `used`, `capacity`, `warning`, `error`, `gauge-used`, `gauge-free`               |
| `activity`                       | `tool`, `waiting`, `compacting`, `failed`, `cancelled`, `no-content`             |
| `diagnostics`                    | `error`, `warning`, `pending`                                                    |
| `tasks`, `blocked`               | `progress`, `current`; `blocked`, respectively                                   |
| `agents`                         | `active`, `failed`, `paused`, `stale`                                            |
| `ci`, `reviews`                  | `failed`; `unresolved`, respectively                                             |
| `statuses`                       | `message`, `error`                                                               |
| `quota`                          | `used`, `reset`, `stale`, `error`                                                |

Other widgets have placement controls but no individual roles. A decorative
prefix does not replace the actual label of a state-only widget. Units,
estimated-cost markers, lower-bound `+` markers and native overflow cues are not
decorative symbols.

## Separators and extension symbols

`separators` accepts an object with optional `widgets` and `regions` members:

```json
{
  "separators": { "widgets": " · ", "regions": " │ " },
  "symbols": {
    "planning": { "alias": "planning", "colour": "accent" },
    "default": "◇"
  }
}
```

`widgets` separates visible placements, not children within a composite widget.
`regions` appears once before a right-hand group when both sides contain values.
The gutter, right alignment and context-gauge budget remain. Without overrides,
the directional Powerline presentation remains active.

Empty strings remove separator decoration; spaces are literal. Separator values
have a maximum of eight terminal columns and 64 UTF-16 code units, and reject
ANSI, controls, format characters, line breaks and nonempty zero-width text. A
string-valued `separators` is invalid. An empty object has no override. Fitting
reduces decorative overhead before omitting actionable readings. Separator
colour uses the theme's border role.

`symbols` is keyed by extension/source ID. Values use the same literal and
object forms as `symbol`. The defaults are `planning: "≡"` and `default: "◇"`;
unknown source IDs are supported. These settings affect markers, not producer
messages or protocols. Placement appearance overrides the corresponding
decoration.

## Saving and resetting

A local-preferences document replaces the base presentation completely. It is
not a merged patch: an omitted region inherits its selected profile, not the
base document. Base appearance changes do not merge into local preferences.

The base alone selects persistence: `"local"` by default, or `"session"` for the
temporary app. Local-preferences documents do not accept `persistence`. Session
application ends on reload or session switch and writes no settings file.

The save destination is fixed for the editing interaction:

| Source state                           | Destination                                                           |
| -------------------------------------- | --------------------------------------------------------------------- |
| Local preferences exist                | The same local-preferences file, if suitable.                         |
| Writable regular base                  | The base file.                                                        |
| Missing base with a writable directory | A new base file.                                                      |
| Symlinked or non-writable regular base | The sibling user file, if suitable, with first-creation confirmation. |
| Unsuitable destination                 | A save error; no automatic redirection.                               |

Saving checks the final path without following a link. Existing destinations
must be writable regular files, and their directory must permit replacement.
Creation and removal also require directory permissions. Source revisions and
destination identity are checked again before the atomic rename. New files use
restrictive permissions; existing file modes are retained.

Invalid local preferences fall back to the base with a diagnostic. An invalid
base uses the built-in Rich fallback unless valid local preferences supersede
it. Replacing an invalid source requires repair confirmation. Save errors retain
the draft and preview; using that draft for the session requires its own action.

Reset to base settings stages the base appearance and removal of the user file.
Only the main save action confirms and commits that removal. Cancelling leaves
the user file unchanged.

Home Manager can still specify the base declaratively:

```nix
home.file.".pi/agent/session-footer.json".text = lib.mkForce (builtins.toJSON {
  preset = "compact";
  "top-left" = ["directory" "git" "git-conflicts"];
});
```

## Measurement scopes

- Quota percentages are used, not remaining. Readings become stale after 30
  seconds and expire after five minutes or reset. `↻` is a reset countdown.
- Session cost includes recorded branches, summaries, cache warming and reported
  tool usage. `$` is provider-reported billed cost; `≈$` is a recorded estimate.
  Auxiliary and delegation accounting remain separate from session cost.
- Inline cache hit rate uses the last active-branch prompt. The denominator is
  input plus cache read plus cache write tokens. The widget page includes its
  captured numerator and denominator. Usage details also show the whole-session
  rate. Neither rate measures invoice savings.
- Active-work time covers observed activity. Timing details show when
  observation began. Run and compaction durations describe their current
  activity.
- Git file counts refer to paths; a path can have staged and unstaged changes.
  Ahead/behind counts refer to commits in the last fetched upstream state.
- Diagnostics describe received events. Pending and truncated reports remain
  visible; `+` marks lower-bound counts. Coverage details are available
  separately.
- Active child counts use fleet totals. Failed and paused run details can be
  incomplete or stale, and retain those indicators.

Explain freezes a completed ordinary frame. It retains fitted values, symbols,
colours and placement decisions without fitting again at the inspector's width.
Unsaved preview frames never replace that capture. Domain views use current
observations. Only entering Usage refreshes the existing delegation-cost report.

See the [integration contracts] for status publications and editor ownership.

[integration contracts]: integrations.md
