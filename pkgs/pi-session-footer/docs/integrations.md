# Integration contracts

The footer consumes status already published by Pi and its extensions.
Inspection and appearance previews do not start model calls, quota fetches,
workspace diagnostic probes or PR watching. Entering Usage retains the existing
read-only refresh of delegation accounting.

## Cooperative extension status

The native `pi.events` bus has no runtime package dependency between producers
and this consumer. Producers publish on `dotfiles:status:v1`:

```typescript
type StatusPublication = {
  version: 1;
  source: string;
  sessionId: string;
  active: boolean;
  text?: string;
};
```

Consumers request a replay on `dotfiles:status:request:v1`:

```typescript
type StatusRequest = {
  version: 1;
  sessionId: string;
};
```

A producer publishes semantic state on changes and answers replay requests only
for the matching native session ID. It clears its publication and removes its
request listener on shutdown.

The footer requests snapshots at session start and accepts subsequent snapshots
only for that session. Invalid or wrong-version input is ignored. Text is
sanitised and bounded. Display labels are not parsed for meaning.

Planning publishes source `planning` with its real active flag. Active planning
shows its configured symbol, followed by optional producer text. There is no
inferred implementation phase. Inactive snapshots hide the status and suppress
stale native messages for that source.

Cooperative source keys are excluded from generic duplicates even when their
dedicated widget is disabled. Other cooperative sources use their configured
marker or `default`. Older publishers retain sanitised native messages with
their original labels. Planning retains its native status when used without this
footer.

## Other sources

- Quota and service-tier state come from the existing sub-core publications.
- Tasks use recorded native todo results. Agent status and delegation accounting
  use the existing subagent RPC contracts.
- Diagnostics consume Lens findings and touched-file events. Coverage describes
  received events, not a workspace-wide cleanliness result.
- Repository status uses the existing Git reader. GitHub state comes from
  [pi-prs]; its native commands control watching and automatic feedback.
- Session and auxiliary usage use their recorded ledgers. The cache fraction
  retains the same active-branch prompt as the inline percentage.

Missing publications do not establish healthy integrations. Source, coverage,
freshness, errors and accounting definitions remain available in the relevant
inspection detail pages.

[pi-prs]: https://github.com/mavam/pi-prs

## Native editor ownership

The composer mounts after extension startup and supports either Pretty load
order. It uses the native editor for input, cursor movement, completion,
history, undo, paste, images and shortcuts. Working, retry and compaction
indicators remain under Pi's control.

The footer suppresses standalone rows while its composer owns the editor. If
another extension installs an editor, the footer does not reinstall its own
editor. Configured nonempty rows then use the standalone-footer fallback. Reload
and shutdown restore the previous editor factory only while the footer still
owns the mounted factory.

A border render observes data once. Its completed callback reports the actual
composer height, completion rows and rendered lines. Appearance is applied
before width fitting. Placement evidence records the fitted text, runs, symbols,
variants and priorities for Explain.

## Customiser focus and lifecycle

One native widget above the editor contains the complete editing flow. Native
input and selection components operate inside that widget; configuration pages
do not displace the composer or create a second preview.

The dock uses public focus and screen-snapshot APIs. A nested overlay can retain
the dock as its return target, so removal waits until that target is released.
The dock restores focus only to the appropriate mounted target. If an extension
replaces the editor during editing, focus can return to that replacement; the
footer does not reconstruct an editor.

Reported composer geometry bounds the controls. The visibility check also
accounts for other widgets and the rendered viewport. If controls and the footer
cannot fit, editing pauses, active appearance returns, and a visible
resize/retry/cancel screen replaces input capture.

Root cancellation, abnormal disposal, superseding inspection, session switch,
reload and shutdown discard the draft. Interaction and session identities
prevent stale callbacks from applying a later change. Appearance rollback uses
current observations, not old metric values. Persistence commits synchronously
at the checked atomic rename; there is no delayed writer or settings watcher.

The [configuration reference] describes destinations, validation and measurement
scopes. Native regressions are in [the dock tests], [the customiser tests] and
[the composer scenarios].

[configuration reference]: reference.md
[the dock tests]: ../test/integration/dock.test.ts
[the customiser tests]: ../test/integration/customiser-flow.test.ts
[the composer scenarios]: ../test/integration/tui.test.ts
