# Session footer

Keep model, context and session status beside your prompt. Preview and customise
with `/footer config`, or see what each field means with `/footer explain`.

![Choose a profile, then tune its symbols and colours][walkthrough]

[walkthrough]: demo/footer.webp

## Choose a profile

| Profile  | Use it for                                                       |
| -------- | ---------------------------------------------------------------- |
| Rich     | Model identity, work in progress and session usage. The default. |
| Compact  | Model identity and context, with no bottom status row.           |
| Minimal  | Directory, Git and context.                                      |
| Workflow | Work and attention, with quota at the bottom right.              |

The footer shortens routine detail before actionable warnings. Wider terminals
restore the full values. Colours follow Pi's theme; symbols and labels also
identify the state.

![Rich profile with context, cache hit rate and session cost][usage]

![Minimal profile in Pi's light theme][minimal]

[usage]: demo/usage.png
[minimal]: demo/minimal.png

## Explain a field

`/footer` and `/footer explain` open a scrollable legend of the displayed
footer. Choose a field to explain its value and symbols. A direct command, such
as `/footer explain cache`, opens the same page.

![Scroll through the displayed fields][legend]

![Explain the cache hit rate and cached prompt tokens][cache]

Use the displayed bindings to navigate, page and go back. Selection and scroll
position remain when you return from a detail page or change sections. The
Sections menu includes Overview, Quota, Workflow, Diagnostics, Git, Usage and
Help.

Explain keeps the completed display fixed while you inspect it. Rendering
details contains its timestamp, width budgets and fitting decisions. The Help
widget catalogue also includes fields that are not currently visible.

[legend]: demo/legend.png
[cache]: demo/explain.png

## Customise the live footer

Open `/footer config`. Every page previews the same footer beneath the controls:
profiles, widget order, symbols, colours, separators and extension symbols.

- Choosing a field accepts that edit into the draft, without saving it.
- Going back from a field cancels its pending choice.
- Choosing Save & use on the main Customise screen saves the complete draft.
- Cancelling the main screen discards the draft and restores the active
  appearance.

![Preview a profile before accepting it][profile]

![Set a symbol colour independently from its text colour][appearance]

Your prompt draft and native editing remain intact. The footer supports both
Pretty load orders. See the [integration contracts] for ownership and extension
status details.

[profile]: demo/config.png
[appearance]: demo/appearance.png
[integration contracts]: docs/integrations.md

### Saving

Source & saving shows the active source and the destination. The customiser
updates a writable regular settings file. For a symlinked or read-only base, it
can create `session-footer.user.json` beside the base after confirmation. User
settings replace the base appearance until you reset them.

The temporary Pi app offers **Use for this session**. Those changes end on
reload or session switch. A failed save keeps the draft available for retry;
session application is a separate choice.

### JSON settings

The base file is `session-footer.json` in Pi's selected agent directory. A
profile needs only:

```json
{ "preset": "compact" }
```

Use widget strings for default appearance. An omitted region inherits the
profile; an array replaces that region, and `[]` disables it.

```json
{
  "preset": "rich",
  "top-left": ["model", "thinking", "directory", "git"],
  "top-right": ["context"],
  "bottom-left": []
}
```

An object customises one placement. Symbol and text colours are independent:

```json
{
  "top-left": [
    "model",
    {
      "id": "git",
      "colour": "text",
      "symbol": { "alias": "git", "colour": "accent" }
    }
  ],
  "separators": { "widgets": " · " }
}
```

Symbol strings are literal: `"git"` displays the text `git`. Use an explicit
alias object for a built-in symbol. The [configuration reference] describes all
widgets, individual parts, validation, persistence and measurement scopes.

[configuration reference]: docs/reference.md

## Commands

| Command                 | Purpose                                    |
| ----------------------- | ------------------------------------------ |
| `/footer explain`       | Explain the displayed footer.              |
| `/footer explain cache` | Explain one widget.                        |
| `/footer config`        | Preview and customise.                     |
| `/footer help`          | Commands, widget catalogue and navigation. |
| `/footer`               | Same as `/footer explain`.                 |

The demonstrations use synthetic responses and usage from a local provider, with
sample Git changes. Recording instructions are in the [demo guide].

[demo guide]: demo/README.md

For package commands and Nix development dependencies, see the [developer
guide].

[developer guide]: docs/development.md
