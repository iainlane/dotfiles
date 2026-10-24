# Pi integration programme

The combined Pi PR has two deliverables: principled engineering across the
complete integration, and a composed, Claude-style planning experience.
Completing Plan mode alone does not complete this programme.

The baseline is `578f266de78895617caaa23794c97e6f22aa2bb4`, with Pi 1.4.0.
Findings below refer to those pinned packages, not whichever version is active
in a user's Home Manager generation.

## Package decisions

Retain authentication, live models, PR integration, prompt routing, web access,
subagents, execution tasks and the local footer. Each provides a distinct
capability. Prefer native features and supported configuration over adapters.
The footer consumes upstream state; upstream packages own polling and task
management. Service-tier controls apply to parent requests; the installed
subagent runtime does not implement their child-inheritance protocol.

Replace the existing Plan-mode package and `plan-explore` adapter with focused
planning policy, storage and review around the existing subagent runtime and the
upstream general-purpose question extension. Remove unused `pi-footer` and
`pi-system-theme` packages.

Keep pi-pretty narrowly configured, Lens reproducibly provisioned, and the
notification, simplify and side-question commands after the fixes below. The
pi-diff fixes are published on the `pi-integration-fixes` branch of
`iainlane/pi-diff` and pinned by commit. The pi-pretty codemode contribution
remains separately owned.

## Upstream maintenance

The baseline contains six patches across five packages. Further changes affect
five upstream extensions, including three previously unpatched packages. The Pi
Diff fork removes its SDK-import patch, leaving twelve local patches across
seven packages. Both patches and fork pins create maintenance work.

| Package        | Baseline adaptation               | Additional work                                                               |
| -------------- | --------------------------------- | ----------------------------------------------------------------------------- |
| pi-diff        | Host SDK imports                  | Use the source-built fork and remove the SDK-import patch                     |
| pi-live-models | Offline refresh and cache pricing | Retain both bounded fixes                                                     |
| pi-pretty      | Native theme integration          | Correct partial-read numbering and continuation rendering                     |
| pi-sub-core    | Quota metadata                    | Non-blocking refresh and current credential discovery                         |
| rpiv-todo      | Widget visibility                 | Retain the bounded fix                                                        |
| pi-notify      | None                              | Final-settlement notifications in TUI mode only                               |
| pi-simplify    | None                              | Empty selections and invalid references must not expand scope                 |
| rpiv-btw       | None                              | Remove cross-session hints; separately improve API and accounting integration |

Prepare an upstream contribution for each generally applicable change. Each
contribution needs a proposed PR draft with its code, rationale and regression
evidence before a fresh, context-blind adversarial subagent reviews the draft.
Do not start those reviews from an earlier diagnosis or an unfinished patch.
Resolve findings before submission and record the upstream PR and the release
that removes the local adaptation. Cross-session hint control should be an
upstream configuration option; unconditional removal remains local policy.

Use supported configuration first. Prefer a fixed upstream release; otherwise
use a narrow versioned patch or immutable fork. Keep correctness fixes and
enhancements in separate commits. Tests must reproduce the affected upstream
boundary. Remove a patch when the pinned release provides equivalent behaviour.
Reassess retaining an extension if its changes become broad or invasive.

Lens's dependency and grammar changes are packaging work. New Plan-mode code is
local development. Neither is an upstream extension patch.

## Logical commits

1. Preserve this audit and the amended Claude research report.
2. Constrain dependency projection and stage updater outputs before replacement.
3. Normalise local npm packaging, SDK versions and TypeScript test helpers.
4. Provision Lens grammars and diagnostics explicitly; remove obsolete
   overrides.
5. Restore native search and correct pi-pretty read rendering.
6. Correct notification settlement and runtime-mode handling.
7. Resolve quota credentials per refresh and stop blocking agent progress.
8. Preserve activity time across repeated starts, retries and waits.
9. Remove cross-session hints from side questions.
10. Use public side-call APIs and record auxiliary usage outside model context.
11. Correct simplify's explicit Git scopes and errors.
12. Add the general question extension without its companion workflow skill.
13. Implement durable plans and revision-bound review and approval.
14. Enforce planning capabilities in parent, child and nested codemode calls.
15. Define fresh-context Explore and Plan roles using public subagent APIs.
16. Implement parent understanding, design, review, finalisation and approval.
17. Complete entry, interruption, resume, compaction and implementation handoff.
18. Switch managed configuration and remove superseded packages and adapters.
19. Integrate and validate the separately owned pi-diff fork when available.
20. Rewrite relevant READMEs around purpose, usage and meaningful limitations.
21. Validate and independently review the complete integration and final
    revision.
22. Prepare the upstream contribution drafts, then independently review each
    proposed draft with a context-blind adversarial subagent. Keep submission
    status and removal conditions in the contribution inventory.

Every behavioural commit includes regression tests. All new extension and test
code is TypeScript. Package-owned checks run during normal builds. Use ordinary
Nix/npm conventions, and share behaviour only when the abstraction is useful.

## Acceptance

Check installed artefacts with the pinned Pi host, not registration alone.
Exercise dependency failures, updater failures, actual tool results, selected
LSP diagnostics, all advertised grammar assets and the deployed helper wrapper.
Local MCP fixtures must validate generated identifiers without external calls.

Cover RPC/JSON output, stalled quota requests, credential rotation, repeated
activity events, cross-session isolation and auxiliary accounting. Exercise
reload, shutdown, cancellation and session replacement with the composition.

Plan tests cover entry, questions, mutation restrictions, shell policy,
delegation, approval revisions, rejection, cancellation, resume, forks,
compaction and both implementation handoffs. Assert capabilities and results; do
not duplicate whole prompts. Assess tasks separately for planning quality.

Run package checks, evaluation with import-from-derivation disabled, native
flake checks and required CI. Record live-provider and cross-platform limits
honestly. Every retained component and patch needs a justified disposition and
evidence. Installation, activation, deployment and merge are outside this
programme.

## Newly observed dependency advisories

The registry audit reports Undici advisories affecting the pinned Pi SDK and
pi-subagents dependency graphs (versions below 8.12.2). The planning package
reuses the managed subagent runtime, so it does not create a second runtime to
update separately. The advisory report does not establish exploitability in
these integrations. Track an upstream host/runtime update separately; package
and behaviour checks do not clear a dependency advisory.
