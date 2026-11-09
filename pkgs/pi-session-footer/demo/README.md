# Standalone footer recordings

The [runner] starts native Pi in a temporary Git workspace with only this
package's `index.ts` extension. Discovery, MCP, skills, context files, prompt
templates and tools are disabled. Pretty and other status producers are absent.

A loopback provider returns scripted text and synthetic usage: 16,384 prompt
tokens, including 4,096 cached tokens, and 240 output tokens. Model capabilities
and prices are synthetic. The workspace includes one staged, one modified and
one untracked file.

Pi receives a private home, agent directory and XDG directories, without
inherited credentials or settings. Its dummy key is for the loopback server. The
runner stops that server and removes the workspace when Pi exits. It does not
contact a public model service, quota collector, diagnostic service, PR watcher
or child agent.

[runner]: run.ts

## Run interactively

Use Node 24 or newer, Git, native Pi 1.5 and the package's installed
dependencies. For repository work, use the Nix development dependencies so Pi's
patches match the packaged extension. From `pkgs/pi-session-footer`:

```sh
node demo/run.ts
node demo/run.ts --preset minimal --theme light
```

`PI_TEST_HOST` selects a native Pi executable when `pi` on `PATH` is unsuitable.
Do not use the configured `nix run .#pi` app for recordings.

Type `Show the scripted summary.` to produce the usage readings. Then try:

- `/footer explain`: scroll the legend and choose a field.
- `/footer explain cache`: open its captured fraction directly.
- `/footer config`: preview a profile, then change a widget, symbol, colour or
  separator.

In Customise, Enter accepts a field into the draft. Escape from the main screen
cancels that draft. Save & use writes only this temporary workspace's settings;
it cannot change the live agent directory. Clear the prompt and press Ctrl+D to
exit Pi.

## Edit the fixture

The runner and tests use the typed [fixture]. It specifies model metadata,
prices, response chunks, usage and Git files. Response `atMs` values are offsets
from the start of streaming. Files distinguish staged, modified and untracked
content.

Terminal dimensions and keyboard steps are in the tapes. Update their screen
waits and screenshot captions when fixture text or measurements change. Do not
add other integrations or public calls to populate a recording.

[fixture]: fixture.ts

## Re-record

Install [VHS], its browser/ttyd dependencies, FFmpeg with animated WebP support,
and CaskaydiaMono Nerd Font Mono. From the package directory:

```sh
bash demo/record.bash
```

The script validates and runs all four tapes. It converts the two walkthroughs
to animated WebP, removes their temporary GIFs and crops the four composer
screenshots to the bottom 120 pixels. Inspector and customiser screenshots keep
the complete viewport.

| Tape           | Captures                                                                                                                 |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ |
| [footer.tape]  | Rich layout, usage, profile cancellation, widget editing, independent colours, separators, extension symbols and saving. |
| [explain.tape] | A scrolling narrow legend, cache details and selection-preserving back navigation.                                       |
| [narrow.tape]  | Rich at 60 columns.                                                                                                      |
| [minimal.tape] | Minimal with Pi's light theme.                                                                                           |

The tapes wait for native screen content before advancing. Slash commands pause
for argument completion, then use Enter twice to complete and execute. New files
from an interrupted recording can be overwritten by the next run.

`record.bash` changes only generated assets in this directory. It does not
change the live Pi installation or settings. Review the PNGs and sample frames
from both WebP files after recording.

[VHS]: https://github.com/charmbracelet/vhs
[footer.tape]: footer.tape
[explain.tape]: explain.tape
[narrow.tape]: narrow.tape
[minimal.tape]: minimal.tape

## Tests

The unit fixture tests cover the plain-Node CLI, isolated workspace, streaming
response and cleanup. Native PTY scenarios in [the demo tests] run rich and
minimal through the same runner. Run them with the package's integration command
or Nix build.

The PTY adapter is written in TypeScript and uses Homebridge's native bindings.
Cleanup tests cover resistant descendants and an exited group leader. Python is
not required by this package's test infrastructure.

[the demo tests]: ../test/integration/demo.test.ts
