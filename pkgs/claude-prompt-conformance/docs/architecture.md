# Architecture

## Configuration

The suite takes its whole configuration as command-line flags, which name the
manifests and directories a run loads. The package wrapper adds the flags of the
suite itself; the `ai` feature adds the flags which name the prompt under test
and exposes the result as `nix run .#claude-prompt-conformance`. The program
itself draws no distinction between the two groups: it assembles one runtime
configuration from the parsed arguments, and a run retains that configuration as
JSON so it can be resumed and fingerprinted.

## Capability interfaces

The backend talks only to capability interfaces for instance allocation,
repository materialisation, prompt overlay installation, candidate execution,
workspace inspection, verification, judging, and events. Production composition
selects the platform adapter and concrete clients. Unit tests inject fakes for
every backend capability and compare complete domain structures. Platform tests
compare complete Seatbelt profiles and Bubblewrap commands.

Pre-commit builds `claude-prompt-conformance.tests.python`, which runs Ruff,
BasedPyright, pytest, and import checks while building the Python package. Its
source includes only the Python code, tests and package metadata, so changes to
prompts, model defaults or fixtures reuse the cached package.

CI also builds the fixture-environment check, the three client checks below, and
the `ai` feature's configuration check. Together they realise a fixture
toolchain, drive the pinned clients without credentials or external model
requests, and run the configured program far enough to print its catalogue. Run
the same checks locally with:

```console
nix build --no-link \
  .#claude-prompt-conformance.tests.fixtureEnvironments \
  .#claude-prompt-conformance.tests.codexProtocol \
  .#claude-prompt-conformance.tests.codexEndpoint \
  .#claude-prompt-conformance.tests.claudeEndpoint \
  ".#checks.$(nix config show system).prompt-conformance-configuration"
```

## Client checks

Three of those checks drive the pinned clients themselves.

A protocol check reads the effective configuration of an isolated Codex
instance.

A Codex endpoint check completes a whole model turn against a scripted Responses
endpoint on loopback, so the packaged client, its code-mode host, and the
evidence MCP server are exercised together. A client upgrade which severs the
chain from the model to the tools to the evidence fails this check before it can
fail a billed run.

A Claude endpoint check likewise completes a real candidate turn, including a
tool permission denial, against a scripted Messages endpoint, and decodes every
emitted stream record against this suite's schema. Upstream publishes no schema
for that stream, so this check is what catches client drift.

## Closure pinning

A run pins its own program closure. Startup reads every document input into
memory, but the pinned clients, the evidence MCP server, and the fixture
toolchains are executed from the Nix store throughout the run. Startup therefore
registers an indirect garbage-collector root on every store path its
configuration names, and releases them on exit. The links live under
`XDG_RUNTIME_DIR`, or in the per-user temporary directory when that variable is
unset, as on macOS. The next run to start removes the links of runs whose
process is gone, and Nix prunes the then-dangling indirect roots at its next
collection.

## Progress

Progress is an observable tree of scoped task runs. Each task owns its state,
children, parent relationship, and typed signal. Child changes propagate through
that relationship, and execution context supplies the parent when concurrent
work creates a child.

A task declares one of three child policies. Fixed tasks name every child and
give it a relative weight; the weights are normalised to the parent's whole
progress region. Bounded tasks may discover up to a declared maximum and reserve
pessimistic space for every possible child until sealed. Unbounded tasks remain
indeterminate until sealed. Sealing either open policy turns its discovered
children into an ordinary determinate allocation.

The Rich frontend renders immutable snapshots of this tree; the JSON frontend
serialises the same typed task changes, allocations, current operations, and
heartbeats without introducing frontend concepts into the backend. Judge
calibration exposes each reference subject as a child task, so repository
preparation, evidence capture, deterministic checks, and judgement each appear
in the progress tree.
