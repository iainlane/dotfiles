import json
import os
import shutil
import stat
from dataclasses import replace
from pathlib import Path

import msgspec
import pytest

from claude_prompt_conformance.cli import main
from claude_prompt_conformance.inputs import (
    CalibrationNameError,
    FixtureNameError,
    MemoryFile,
    MemoryTreeEntry,
    RuntimeInputs,
    RuntimeInputSnapshotDocumentMismatchError,
)
from claude_prompt_conformance.run_store import (
    OutputMarkerDecodeError,
    OutputPathUnmarkedError,
    OutputSnapshotMismatchError,
    RunInvocation,
    RunStore,
    run_fingerprint,
)
from claude_prompt_conformance.storage import (
    RetainedDirectoryChangedError,
    atomic_write,
    directory_identity,
    remove_directory,
    remove_identified_directory,
)

INVOCATION = RunInvocation(
    fixtures=("example",),
    improve=False,
    calibrate=True,
    proposals=0,
    samples=0,
    keep_workspaces=False,
)


def test_removal_handles_read_only_toolchain_trees(tmp_path: Path) -> None:
    """Go marks its module cache directories read-only inside a workspace."""

    root = tmp_path / "results"
    target = root / "fixture" / "instance"
    cache = target / "verification-home" / "go" / "pkg" / "mod" / "errors@v0.9.1"
    cache.mkdir(parents=True)
    (cache / "errors.go").write_text("package errors\n")
    (cache / "errors.go").chmod(0o444)
    cache.chmod(0o555)
    cache.parent.chmod(0o555)

    remove_directory(root, target)

    assert not target.exists()


def test_identified_directory_removal_preserves_a_replacement(tmp_path: Path) -> None:
    output = tmp_path / "results"
    output.mkdir()
    (output / "owned").write_text("owned\n")
    identity = directory_identity(tmp_path, output)

    original = tmp_path / "original"
    output.rename(original)
    output.mkdir()
    (output / "replacement").write_text("replacement\n")

    with pytest.raises(RetainedDirectoryChangedError) as raised:
        remove_identified_directory(tmp_path, output, identity)

    assert (
        raised.value,
        tuple(path.name for path in output.iterdir()),
        tuple(path.name for path in original.iterdir()),
    ) == (
        RetainedDirectoryChangedError(output),
        ("replacement",),
        ("owned",),
    )


def runtime_inputs(
    tmp_path: Path,
    *,
    prompt: str = "Be precise.",
    fixture_name: str = "example",
    calibration_name: str = "known-good",
) -> RuntimeInputs:
    source = tmp_path / "nix-inputs"
    fixture = source / "fixture"
    candidate_context = source / "candidate-context"
    workspace_overlay = source / "workspace-overlay"
    prompt_source = source / "prompt-source"
    variant_source = source / "variant-expression"
    for directory in (
        fixture,
        candidate_context / "rules",
        workspace_overlay / ".claude" / "rules",
        prompt_source / "instructions",
        prompt_source / "output-style",
        variant_source,
    ):
        directory.mkdir(parents=True)

    (fixture / "task.txt").write_text("Make the focused change.\n")
    (fixture / "known-good.txt").write_text("Implemented and checked.\n")
    (candidate_context / "rules" / "global.md").write_text(prompt)
    (workspace_overlay / ".claude" / "rules" / "global.md").write_text(prompt)
    (prompt_source / "instructions" / "AGENTS.md").write_text(prompt)
    (prompt_source / "output-style" / "plain.md").write_text("Be direct.\n")

    fixture_manifest = source / "fixtures.json"
    fixture_manifest.write_text(
        json.dumps(
            [
                {
                    "name": fixture_name,
                    "description": "Make a focused change.",
                    "kind": "author",
                    "use": "working",
                    "category": "repository-change",
                    "tags": ["testing"],
                    "path": str(fixture),
                    "task": str(fixture / "task.txt"),
                    "repository": {
                        "url": "https://example.invalid/repository.git",
                        "revision": "revision",
                    },
                    "comparisonRevision": "base",
                    "environmentPath": "/nix/store/environment/bin",
                    "criteria": [
                        {
                            "id": "focused",
                            "kind": "outcome",
                            "requirement": "The change is focused.",
                        }
                    ],
                    "verification": [
                        {
                            "name": "tests",
                            "command": ["check"],
                            "kind": "gate",
                        }
                    ],
                    "calibration": [
                        {
                            "name": calibration_name,
                            "repository": {
                                "url": "https://example.invalid/repository.git",
                                "revision": "good",
                            },
                            "response": str(fixture / "known-good.txt"),
                            "expectedCriteria": {"focused": True},
                        }
                    ],
                }
            ]
        )
    )
    documents = {
        "run.json": json.dumps(
            {
                "claude": {
                    "effort": "medium",
                    "model": "claude-opus-5",
                    "version": "1.0.0",
                },
                "codex": {
                    "improver": {
                        "contextWindow": 272000,
                        "effort": "high",
                        "model": "gpt-5.6-sol",
                        "serviceTier": "fast",
                        "verbosity": "low",
                    },
                    "judge": {
                        "contextWindow": 272000,
                        "effort": "high",
                        "model": "gpt-5.6-terra",
                        "serviceTier": "fast",
                        "verbosity": "low",
                    },
                    "version": "0.146.0",
                },
                "defaultOutputStyle": "plain",
                "outputStyles": {"plain": "style-hash"},
                "prompt": {"global": "prompt-hash"},
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        "prompt.json": json.dumps({"globalPrompt": {"global": prompt}}) + "\n",
        "settings.json": '{"outputStyle":"plain"}\n',
        "judgement-schema.json": '{"type":"object"}\n',
        "proposal-schema.json": '{"type":"object"}\n',
        "ca-bundle.crt": "certificate\n",
    }
    for name, contents in documents.items():
        (source / name).write_text(contents)
    (variant_source / "variant.nix").write_text(
        "{ baseConfiguration, ... }: baseConfiguration\n"
    )
    (variant_source / "prompt-environment.nix").write_text("{}\n")

    configuration = source / "configuration.json"
    configuration.write_text(
        json.dumps(
            {
                "fixtureManifest": str(fixture_manifest),
                "runMetadata": str(source / "run.json"),
                "promptContext": str(source / "prompt.json"),
                "candidateContext": str(candidate_context),
                "workspaceOverlay": str(workspace_overlay),
                "gitProgram": "/nix/store/git/bin/git",
                "claude": {
                    "program": "/nix/store/claude/bin/claude",
                    "shell": "/nix/store/bash/bin/bash",
                    "settings": str(source / "settings.json"),
                    "model": "claude-opus-5",
                    "effort": "medium",
                    "apiBudgetUsd": "0.75",
                    "outputStyle": "plain",
                    "oauthTokenUrl": "https://claude.invalid/oauth/token",
                    "oauthClientId": "client",
                },
                "codex": {
                    "program": "/nix/store/codex/bin/codex",
                    "mcpProgram": "/nix/store/harness/bin/mcp",
                    "judge": {
                        "model": "gpt-5.6-terra",
                        "effort": "high",
                        "serviceTier": "fast",
                        "verbosity": "low",
                        "contextWindow": 272000,
                    },
                    "improver": {
                        "model": "gpt-5.6-sol",
                        "effort": "high",
                        "serviceTier": "fast",
                        "verbosity": "low",
                        "contextWindow": 272000,
                    },
                    "schema": str(source / "judgement-schema.json"),
                    "proposalSchema": str(source / "proposal-schema.json"),
                    "tlsCertificateBundle": str(source / "ca-bundle.crt"),
                    "oauthTokenUrl": "https://codex.invalid/oauth/token",
                    "oauthClientId": "codex-client",
                },
                "isolation": {"backend": "darwin", "program": "/usr/bin/sandbox-exec"},
                "variant": {
                    "nixProgram": "/nix/store/nix/bin/nix",
                    "nixpkgs": "/nix/store/nixpkgs",
                    "expression": str(variant_source / "variant.nix"),
                    "promptEnvironment": str(variant_source / "prompt-environment.nix"),
                    "promptSource": str(prompt_source),
                },
            }
        )
    )
    return RuntimeInputs.load(configuration)


@pytest.mark.parametrize(
    ("fixture_name", "calibration_name", "expected"),
    [
        ("../outside", "known-good", FixtureNameError("../outside")),
        (
            ".claude-prompt-conformance-state",
            "known-good",
            FixtureNameError(".claude-prompt-conformance-state"),
        ),
        (
            "example",
            "../outside",
            CalibrationNameError("example", "../outside"),
        ),
    ],
)
def test_manifest_names_cannot_escape_the_run_snapshot(
    tmp_path: Path,
    fixture_name: str,
    calibration_name: str,
    expected: Exception,
) -> None:
    outside = tmp_path / "outside"
    outside.write_text("retained\n")

    with pytest.raises(type(expected)) as raised:
        runtime_inputs(
            tmp_path,
            fixture_name=fixture_name,
            calibration_name=calibration_name,
        )

    assert (raised.value, outside.read_text()) == (expected, "retained\n")


def test_run_store_materialises_every_document_after_sources_disappear(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    shutil.rmtree(tmp_path / "nix-inputs")
    output = tmp_path / "results"

    _, runtime = RunStore.open(output, inputs, INVOCATION, unlink_first=False)

    configuration = runtime.configuration
    (fixture,) = runtime.fixtures
    (calibration,) = fixture.calibration
    assert (
        tuple(
            path.relative_to(output)
            for path in (
                configuration.source,
                configuration.fixture_manifest,
                configuration.run_metadata,
                configuration.prompt_context,
                configuration.candidate_context,
                configuration.workspace_overlay,
                configuration.claude.settings,
                configuration.codex.schema,
                configuration.codex.proposal_schema,
                configuration.codex.tls_certificate_bundle,
                configuration.variant.expression,
                configuration.variant.prompt_source,
                fixture.path,
                fixture.task,
                calibration.response,
            )
        ),
        fixture.task.read_text(),
        calibration.response.read_text(),
        (configuration.codex.schema.read_text()),
    ) == (
        (
            Path(".claude-prompt-conformance-state/inputs/configuration.json"),
            Path(".claude-prompt-conformance-state/inputs/fixtures.json"),
            Path(".claude-prompt-conformance-state/inputs/run-metadata.json"),
            Path(".claude-prompt-conformance-state/inputs/prompt-context.json"),
            Path(".claude-prompt-conformance-state/inputs/candidate-context"),
            Path(".claude-prompt-conformance-state/inputs/workspace-overlay"),
            Path(".claude-prompt-conformance-state/inputs/claude-settings.json"),
            Path(".claude-prompt-conformance-state/inputs/judgement-schema.json"),
            Path(".claude-prompt-conformance-state/inputs/proposal-schema.json"),
            Path(".claude-prompt-conformance-state/inputs/ca-bundle.crt"),
            Path(".claude-prompt-conformance-state/inputs/variant-source/variant.nix"),
            Path(".claude-prompt-conformance-state/inputs/prompt-source"),
            Path(".claude-prompt-conformance-state/inputs/fixtures/example/source"),
            Path(".claude-prompt-conformance-state/inputs/fixtures/example/task.md"),
            Path(
                ".claude-prompt-conformance-state/inputs/fixtures/example/calibration/known-good.md"
            ),
        ),
        "Make the focused change.\n",
        "Implemented and checked.\n",
        '{"type":"object"}\n',
    )


def test_existing_run_store_is_resumed_and_unlink_first_starts_again(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    sentinel = output / "completed-evidence"
    sentinel.write_text("retained\n")
    marker = output / ".claude-prompt-conformance"
    pending_marker = output / ".claude-prompt-conformance.interrupted.new"
    marker.rename(pending_marker)

    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    resumed_files = tuple(sorted(path.name for path in output.iterdir()))
    RunStore.open(output, inputs, INVOCATION, unlink_first=True)

    assert (
        resumed_files,
        (marker.is_file(), pending_marker.exists()),
        tuple(sorted(path.name for path in output.iterdir())),
    ) == (
        (
            ".claude-prompt-conformance",
            ".claude-prompt-conformance-state",
            "completed-evidence",
            "prompt-context.json",
            "run-metadata.json",
        ),
        (True, False),
        (
            ".claude-prompt-conformance",
            ".claude-prompt-conformance-state",
            "prompt-context.json",
            "run-metadata.json",
        ),
    )


def test_existing_run_store_rejects_different_inputs_structurally(
    tmp_path: Path,
) -> None:
    output = tmp_path / "results"
    RunStore.open(
        output,
        runtime_inputs(tmp_path / "first"),
        INVOCATION,
        unlink_first=False,
    )

    with pytest.raises(OutputSnapshotMismatchError) as raised:
        RunStore.open(
            output,
            runtime_inputs(tmp_path / "second", prompt="Be concise."),
            INVOCATION,
            unlink_first=False,
        )

    assert raised.value == OutputSnapshotMismatchError(output)


def test_existing_run_store_rejects_a_different_invocation_structurally(
    tmp_path: Path,
) -> None:
    output = tmp_path / "results"
    inputs = runtime_inputs(tmp_path)
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    changed = msgspec.structs.replace(INVOCATION, fixtures=("another",))

    with pytest.raises(OutputSnapshotMismatchError) as raised:
        RunStore.open(output, inputs, changed, unlink_first=False)

    assert raised.value == OutputSnapshotMismatchError(output)


@pytest.mark.parametrize(
    "marker",
    [
        pytest.param(
            '{"promptContext":"prompt-context.json",'
            '"runMetadata":"run-metadata.json"}\n',
            id="unversioned",
        ),
        pytest.param(
            '{"promptContext":"prompt-context.json",'
            '"runMetadata":"run-metadata.json","version":2,'
            '"fingerprint":"retained","inputs":'
            '".claude-prompt-conformance-state/inputs","ready":true}\n',
            id="version-two",
        ),
    ],
)
def test_a_store_in_an_old_format_is_rejected_with_recovery_guidance(
    tmp_path: Path,
    marker: str,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    output.mkdir()
    inputs.run_metadata.materialise(output / "run-metadata.json")
    inputs.prompt_context.materialise(output / "prompt-context.json")
    marker_path = output / ".claude-prompt-conformance"
    marker_path.write_text(marker)

    with pytest.raises(OutputSnapshotMismatchError) as raised:
        RunStore.open(output, inputs, INVOCATION, unlink_first=False)

    assert (raised.value, str(raised.value), marker_path.read_text()) == (
        OutputSnapshotMismatchError(output),
        (
            f"output directory {output} belongs to different run inputs; "
            "use --unlink-first to remove it and start again"
        ),
        marker,
    )


def test_a_store_written_for_another_format_version_is_rejected(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    marker_path = output / ".claude-prompt-conformance"
    marker = msgspec.json.decode(marker_path.read_bytes())
    marker_path.write_bytes(
        msgspec.json.encode(marker | {"fingerprint": "another-store-format"})
    )

    with pytest.raises(OutputSnapshotMismatchError) as raised:
        RunStore.open(output, inputs, INVOCATION, unlink_first=False)

    assert raised.value == OutputSnapshotMismatchError(output)


def test_resume_identity_treats_the_fixture_selection_as_a_set(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    selection = msgspec.structs.replace(INVOCATION, fixtures=("beta", "alpha"))
    reordered = msgspec.structs.replace(INVOCATION, fixtures=("alpha", "beta"))
    RunStore.open(output, inputs, selection, unlink_first=False)
    marker = msgspec.json.decode((output / ".claude-prompt-conformance").read_bytes())

    _, runtime = RunStore.open(output, inputs, reordered, unlink_first=False)

    assert (
        selection,
        run_fingerprint(inputs, selection) == run_fingerprint(inputs, reordered),
        marker["invocation"]["fixtures"],
        runtime.configuration.source,
    ) == (
        reordered,
        True,
        ["alpha", "beta"],
        output / ".claude-prompt-conformance-state" / "inputs" / "configuration.json",
    )


def test_resume_identity_rejects_a_changed_judge_configuration(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    metadata = msgspec.json.decode(inputs.run_metadata.contents)
    metadata["codex"]["judge"]["model"] = "gpt-5.6-luna"
    changed = replace(
        inputs,
        run_metadata=replace(
            inputs.run_metadata,
            contents=msgspec.json.encode(metadata),
        ),
    )

    with pytest.raises(OutputSnapshotMismatchError) as raised:
        RunStore.open(output, changed, INVOCATION, unlink_first=False)

    assert (
        raised.value,
        run_fingerprint(changed, INVOCATION) == run_fingerprint(inputs, INVOCATION),
    ) == (OutputSnapshotMismatchError(output), False)


def test_atomic_write_commits_the_file_and_then_its_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    synchronised: list[str] = []
    commit = os.fsync

    def record(descriptor: int) -> None:
        mode = os.fstat(descriptor).st_mode
        synchronised.append("directory" if stat.S_ISDIR(mode) else "file")
        commit(descriptor)

    monkeypatch.setattr(os, "fsync", record)
    destination = tmp_path / ".claude-prompt-conformance-state" / "document.json"

    atomic_write(tmp_path, destination, b"retained\n")

    assert (synchronised, destination.read_bytes()) == (
        ["file", "directory"],
        b"retained\n",
    )


def test_atomic_write_adopts_a_parent_directory_another_arm_created(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    make_directory = os.mkdir

    def racing_mkdir(
        name: str,
        mode: int = 0o777,
        *,
        dir_fd: int | None = None,
    ) -> None:
        """Let a concurrent arm of the same run store win every creation."""

        make_directory(name, mode, dir_fd=dir_fd)
        make_directory(name, mode, dir_fd=dir_fd)

    monkeypatch.setattr(os, "mkdir", racing_mkdir)
    destination = (
        tmp_path / ".claude-prompt-conformance-state" / "calibration" / "example.json"
    )

    atomic_write(tmp_path, destination, b"retained\n")

    assert destination.read_bytes() == b"retained\n"


def test_publishing_a_new_run_store_commits_its_parent_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    synchronised: list[tuple[int, int]] = []
    commit = os.fsync

    def record(descriptor: int) -> None:
        metadata = os.fstat(descriptor)
        synchronised.append((metadata.st_dev, metadata.st_ino))
        commit(descriptor)

    monkeypatch.setattr(os, "fsync", record)
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)

    parent = output.parent.stat()
    assert synchronised[-1] == (parent.st_dev, parent.st_ino)


def test_resume_rejects_a_snapshot_symlink_without_writing_through_it(
    tmp_path: Path,
) -> None:
    output = tmp_path / "results"
    inputs = runtime_inputs(tmp_path)
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    rules = output / ".claude-prompt-conformance-state/inputs/candidate-context/rules"
    shutil.rmtree(rules)
    outside = tmp_path / "outside"
    outside.mkdir()
    rules.symlink_to(outside, target_is_directory=True)

    with pytest.raises(RuntimeInputSnapshotDocumentMismatchError) as raised:
        RunStore.open(output, inputs, INVOCATION, unlink_first=False)

    assert (raised.value, tuple(outside.iterdir())) == (
        RuntimeInputSnapshotDocumentMismatchError(rules),
        (),
    )


def test_run_identity_covers_every_class_of_controlled_input(tmp_path: Path) -> None:
    inputs = runtime_inputs(tmp_path)
    (fixture,) = inputs.fixtures
    extra = MemoryTreeEntry(Path("extra"), MemoryFile(b"different", False))
    declaration = msgspec.structs.replace(
        inputs.declaration,
        claude=msgspec.structs.replace(
            inputs.declaration.claude,
            api_budget_usd="1.25",
        ),
    )
    fingerprints = tuple(
        candidate.fingerprint()
        for candidate in (
            inputs,
            replace(inputs, declaration=declaration),
            replace(
                inputs,
                run_metadata=replace(inputs.run_metadata, executable=True),
            ),
            replace(inputs, tls_certificate_bundle=MemoryFile(b"new CA", False)),
            replace(
                inputs,
                candidate_context=replace(
                    inputs.candidate_context,
                    files=(*inputs.candidate_context.files, extra),
                ),
            ),
            replace(
                inputs,
                workspace_overlay=replace(
                    inputs.workspace_overlay,
                    files=(*inputs.workspace_overlay.files, extra),
                ),
            ),
            replace(
                inputs,
                prompt_source=replace(
                    inputs.prompt_source,
                    files=(
                        *inputs.prompt_source.files,
                        replace(extra, relative=Path("instructions/extra.md")),
                    ),
                ),
            ),
            replace(
                inputs,
                prompt_source=replace(
                    inputs.prompt_source,
                    files=(
                        *inputs.prompt_source.files,
                        replace(
                            extra,
                            relative=Path("prompt-conformance/backend.py"),
                        ),
                    ),
                ),
            ),
            replace(
                inputs,
                variant_source=replace(
                    inputs.variant_source,
                    files=(*inputs.variant_source.files, extra),
                ),
            ),
            replace(
                inputs,
                fixtures=(
                    replace(
                        fixture,
                        tree=replace(
                            fixture.tree,
                            files=(*fixture.tree.files, extra),
                        ),
                    ),
                ),
            ),
        )
    )

    base, *_ = fingerprints
    assert tuple(fingerprint == base for fingerprint in fingerprints) == (
        True,
        False,
        False,
        False,
        False,
        False,
        False,
        True,
        False,
        False,
    )


def test_run_identity_is_stable_after_materialising_its_snapshot(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    snapshot = tmp_path / "snapshot"

    inputs.materialise(snapshot)
    retained = RuntimeInputs.load(snapshot / "configuration.json")

    assert retained.fingerprint() == inputs.fingerprint()


def test_incomplete_versioned_initialisation_is_rebuilt(tmp_path: Path) -> None:
    inputs = runtime_inputs(tmp_path)
    output = tmp_path / "results"
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    marker_path = output / ".claude-prompt-conformance"
    marker = msgspec.json.decode(marker_path.read_bytes())
    marker_path.write_bytes(msgspec.json.encode(marker | {"ready": False}))
    state = output / ".claude-prompt-conformance-state"
    sentinel = state / "incomplete"
    sentinel.write_text("partial\n")

    _, runtime = RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    rebuilt = msgspec.json.decode(marker_path.read_bytes())

    assert (
        runtime.configuration.source,
        sentinel.exists(),
        rebuilt,
    ) == (
        state / "inputs/configuration.json",
        False,
        marker,
    )


def test_invalid_unlink_first_invocation_preserves_the_existing_store(
    tmp_path: Path,
) -> None:
    inputs = runtime_inputs(tmp_path)
    configuration = tmp_path / "nix-inputs" / "configuration.json"
    output = tmp_path / "results"
    RunStore.open(output, inputs, INVOCATION, unlink_first=False)
    sentinel = output / "completed-evidence"
    sentinel.write_text("retained\n")
    before = tuple(
        (path.relative_to(output), path.read_bytes())
        for path in sorted(output.rglob("*"))
        if path.is_file()
    )

    status = main(
        (
            str(configuration),
            str(output),
            "--all",
            "--improve",
            "--skip-calibration",
            "--unlink-first",
            "--format",
            "json",
        )
    )
    after = tuple(
        (path.relative_to(output), path.read_bytes())
        for path in sorted(output.rglob("*"))
        if path.is_file()
    )

    assert (status, before, after) == (2, before, before)


def test_unlink_first_never_claims_an_unmarked_directory(tmp_path: Path) -> None:
    output = tmp_path / "results"
    output.mkdir()

    with pytest.raises(OutputPathUnmarkedError) as raised:
        RunStore.open(
            output,
            runtime_inputs(tmp_path),
            INVOCATION,
            unlink_first=True,
        )

    assert raised.value == OutputPathUnmarkedError(output)


def test_unlink_first_never_claims_a_directory_with_a_symlinked_marker(
    tmp_path: Path,
) -> None:
    legitimate = tmp_path / "legitimate"
    RunStore.open(
        legitimate,
        runtime_inputs(tmp_path / "legitimate-inputs"),
        INVOCATION,
        unlink_first=False,
    )
    output = tmp_path / "results"
    output.mkdir()
    marker = output / ".claude-prompt-conformance"
    marker.symlink_to(legitimate / marker.name)

    with pytest.raises(OutputPathUnmarkedError) as raised:
        RunStore.open(
            output,
            runtime_inputs(tmp_path / "untrusted-inputs"),
            INVOCATION,
            unlink_first=True,
        )

    assert (
        raised.value,
        marker.is_symlink(),
        legitimate.is_dir(),
    ) == (
        OutputPathUnmarkedError(output),
        True,
        True,
    )


def test_unlink_first_never_reads_a_non_regular_marker(tmp_path: Path) -> None:
    output = tmp_path / "results"
    output.mkdir()
    marker = output / ".claude-prompt-conformance"
    marker.mkdir()

    with pytest.raises(OutputPathUnmarkedError) as raised:
        RunStore.open(
            output,
            runtime_inputs(tmp_path / "untrusted-inputs"),
            INVOCATION,
            unlink_first=True,
        )

    assert (raised.value, marker.is_dir(), output.is_dir()) == (
        OutputPathUnmarkedError(output),
        True,
        True,
    )


def test_malformed_pending_marker_does_not_claim_an_unmarked_directory(
    tmp_path: Path,
) -> None:
    output = tmp_path / "results"
    output.mkdir()
    pending = output / ".claude-prompt-conformance.new"
    pending.write_text("not JSON\n")

    with pytest.raises(OutputMarkerDecodeError) as raised:
        RunStore.open(
            output,
            runtime_inputs(tmp_path),
            INVOCATION,
            unlink_first=False,
        )

    assert (raised.value.source, pending.read_text()) == (pending, "not JSON\n")
