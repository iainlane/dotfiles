import json
from dataclasses import dataclass, replace
from pathlib import Path

import msgspec
import pytest
from unidiff.errors import UnidiffParseError

from claude_prompt_conformance.improvement import (
    PromptPatchEmptyError,
    PromptPatchFormatError,
    PromptPatchPathsError,
    PromptPatchPrefixError,
    prompt_patch_path,
    validate_prompt_patch,
)
from claude_prompt_conformance.inputs import RuntimeInputs
from claude_prompt_conformance.models import (
    ProcessInvocation,
    ProcessResult,
    PromptProposal,
    PromptProposalChangeMissingError,
    PromptProposalObservationsMissingError,
    PromptProposalReasoningMissingError,
    PromptProposalTitleFormatError,
    PromptProposalTitleMissingError,
)
from claude_prompt_conformance.storage import RetainedPathUnsafeError
from claude_prompt_conformance.variants import (
    NixPromptVariantBuilder,
    PromptVariantBuildError,
    PromptVariantMetadataDecodeError,
    PromptVariantOutputsError,
    PromptVariantResultCountError,
    nix_output_path,
)

from .test_run_store import runtime_inputs


@dataclass(frozen=True)
class FailingVariantRunner:
    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        invocation.stdout.write_text("")
        invocation.stderr.write_text("Nix failed\n")
        return ProcessResult(1)


@dataclass(frozen=True)
class SuccessfulVariantRunner:
    inputs: RuntimeInputs
    output: Path

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        self.inputs.materialise(self.output)
        invocation.stdout.write_text(
            json.dumps([{"outputs": {"out": str(self.output)}}])
        )
        invocation.stderr.write_text("")
        out_link = Path(invocation.command[4])
        out_link.symlink_to(self.output, target_is_directory=True)
        return ProcessResult(0)


@pytest.mark.parametrize(
    ("field", "value", "expected"),
    [
        ("title", "", PromptProposalTitleMissingError()),
        ("title", "two\nlines", PromptProposalTitleFormatError()),
        ("title", "x" * 101, PromptProposalTitleFormatError()),
        ("observations", [], PromptProposalObservationsMissingError()),
        ("change", "", PromptProposalChangeMissingError()),
        ("reasoning", "", PromptProposalReasoningMissingError()),
    ],
)
def test_prompt_proposal_requires_a_complete_improvement_theory(
    tmp_path: Path,
    field: str,
    value: str | list[object],
    expected: Exception,
) -> None:
    contents: dict[str, object] = {
        "noChange": False,
        "title": "clarify evidence reporting",
        "observations": ["Handoffs contradict recorded checks."],
        "change": "Require handoffs to report recorded checks.",
        "reasoning": "The report can be checked against retained evidence.",
        "risks": ["Handoffs may become longer."],
        "patch": "--- a/instructions/a.md\n+++ b/instructions/a.md\n@@ -1 +1 @@\n-a\n+b\n",
    }
    contents[field] = value
    source = tmp_path / "proposal.json"
    source.write_text(json.dumps(contents))

    with pytest.raises(type(expected)) as raised:
        PromptProposal.from_file(source)

    assert raised.value == expected


@pytest.mark.parametrize(
    ("contents", "expected"),
    [
        ("[]", PromptVariantResultCountError(0)),
        (
            (
                '[{"outputs":{"out":"/nix/store/one"}},'
                '{"outputs":{"out":"/nix/store/two"}}]'
            ),
            PromptVariantResultCountError(2),
        ),
        (
            '[{"outputs":{"dev":"/nix/store/dev","doc":"/nix/store/doc"}}]',
            PromptVariantOutputsError(("dev", "doc")),
        ),
    ],
)
def test_nix_output_rejects_non_canonical_result_shapes(
    tmp_path: Path,
    contents: str,
    expected: Exception,
) -> None:
    source = tmp_path / "nix-build.json"
    source.write_text(contents)

    with pytest.raises(type(expected)) as raised:
        nix_output_path(source)

    assert raised.value == expected


def test_nix_output_decodes_the_only_named_output(tmp_path: Path) -> None:
    source = tmp_path / "nix-build.json"
    source.write_text('[{"outputs":{"out":"/nix/store/result"}}]')

    assert nix_output_path(source) == Path("/nix/store/result")


def test_nix_output_retains_decode_failure_context(tmp_path: Path) -> None:
    source = tmp_path / "nix-build.json"
    source.write_text("not JSON")

    with pytest.raises(PromptVariantMetadataDecodeError) as raised:
        nix_output_path(source)

    assert (raised.value.source, type(raised.value.cause)) == (
        source,
        msgspec.DecodeError,
    )


@pytest.mark.parametrize(
    ("patch", "error"),
    [
        ("", PromptPatchEmptyError()),
        (
            "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n",
            PromptPatchPathsError((Path("README.md"),)),
        ),
        (
            (
                "--- a/instructions/../agent-instructions.nix\n"
                "+++ b/instructions/../agent-instructions.nix\n"
                "@@ -1 +1 @@\n-old\n+new\n"
            ),
            PromptPatchPathsError((Path("instructions/../agent-instructions.nix"),)),
        ),
        (
            (
                "diff --git a/private.md b/instructions/new.md\n"
                "similarity index 100%\n"
                "rename from private.md\n"
                "rename to instructions/new.md\n"
            ),
            PromptPatchPathsError((Path("private.md"),)),
        ),
        (
            (
                "--- instructions/agent-instructions.nix\n"
                "+++ instructions/agent-instructions.nix\n"
                "@@ -1 +1 @@\n-old\n+new\n"
            ),
            PromptPatchPrefixError(("instructions/agent-instructions.nix",)),
        ),
        (
            (
                "--- output-style/plain.md\n"
                "+++ output-style/plain.md\n"
                "@@ -1 +1 @@\n-old\n+new\n"
            ),
            PromptPatchPrefixError(("output-style/plain.md",)),
        ),
    ],
)
def test_prompt_patch_rejects_structurally_unsupported_changes(
    patch: str, error: Exception
) -> None:
    with pytest.raises(type(error)) as raised:
        validate_prompt_patch(patch)

    assert raised.value == error


def test_variant_builder_owns_its_output_directory(tmp_path: Path) -> None:
    configuration = (
        runtime_inputs(tmp_path).materialise(tmp_path / "base").configuration
    )
    proposal = PromptProposal(
        False,
        "clarify evidence reporting",
        ("Handoffs contradict recorded checks.",),
        "Require handoffs to report recorded checks.",
        "The report can be verified against retained evidence.",
        (),
        "--- a/instructions/a.md\n+++ b/instructions/a.md\n@@ -1 +1 @@\n-a\n+b\n",
    )
    artefacts = tmp_path / "new" / "variant"

    with pytest.raises(PromptVariantBuildError) as raised:
        NixPromptVariantBuilder(FailingVariantRunner()).build(
            configuration, proposal, artefacts, tmp_path
        )

    assert (
        raised.value,
        tuple(
            (path.relative_to(artefacts), path.read_text())
            for path in sorted(artefacts.iterdir())
        ),
    ) == (
        PromptVariantBuildError(1, artefacts / "nix-variant.stderr"),
        (
            (Path("nix-variant.json"), ""),
            (Path("nix-variant.stderr"), "Nix failed\n"),
            (Path("prompt.patch"), proposal.patch),
        ),
    )


def test_variant_builder_reuses_only_the_same_proposal_and_base_prompt(
    tmp_path: Path,
) -> None:
    base_inputs = runtime_inputs(tmp_path / "base", prompt="base prompt")
    base = base_inputs.materialise(tmp_path / "base-retained").configuration
    first_inputs = runtime_inputs(tmp_path / "first", prompt="first variant")
    first_output = tmp_path / "first-output"
    proposal = PromptProposal(
        False,
        "clarify evidence reporting",
        ("Handoffs contradict recorded checks.",),
        "Require handoffs to report recorded checks.",
        "The report can be verified against retained evidence.",
        (),
        "--- a/instructions/a.md\n+++ b/instructions/a.md\n@@ -1 +1 @@\n-a\n+b\n",
    )
    artefacts = tmp_path / "run" / "variant"
    first = NixPromptVariantBuilder(
        SuccessfulVariantRunner(first_inputs, first_output)
    ).build(base, proposal, artefacts, tmp_path)
    reused = NixPromptVariantBuilder(FailingVariantRunner()).build(
        replace(
            base,
            codex=replace(
                base.codex,
                mcp_program="/nix/store/current-harness/bin/mcp",
            ),
        ),
        proposal,
        artefacts,
        tmp_path,
    )
    initial_contexts = (
        first.prompt_context.read_text(),
        reused.prompt_context.read_text(),
    )

    changed_inputs = runtime_inputs(tmp_path / "changed", prompt="changed base")
    changed = changed_inputs.materialise(tmp_path / "changed-retained").configuration
    second_inputs = runtime_inputs(tmp_path / "second", prompt="second variant")
    second = NixPromptVariantBuilder(
        SuccessfulVariantRunner(second_inputs, tmp_path / "second-output")
    ).build(changed, proposal, artefacts, tmp_path)

    assert (
        initial_contexts,
        reused.codex.mcp_program,
        second.prompt_context.read_text(),
        (artefacts / "nix-result").exists(),
    ) == (
        (
            first_inputs.prompt_context.contents.decode(),
            first_inputs.prompt_context.contents.decode(),
        ),
        "/nix/store/current-harness/bin/mcp",
        second_inputs.prompt_context.contents.decode(),
        False,
    )


def test_variant_cleanup_does_not_follow_an_intermediate_symlink(
    tmp_path: Path,
) -> None:
    configuration = (
        runtime_inputs(tmp_path / "base")
        .materialise(tmp_path / "base-retained")
        .configuration
    )
    proposal = PromptProposal(
        False,
        "clarify evidence reporting",
        ("Handoffs contradict recorded checks.",),
        "Require handoffs to report recorded checks.",
        "The report can be verified against retained evidence.",
        (),
        "--- a/instructions/a.md\n+++ b/instructions/a.md\n@@ -1 +1 @@\n-a\n+b\n",
    )
    outside = tmp_path / "outside"
    victim = outside / "try-01" / "variant"
    victim.mkdir(parents=True)
    sentinel = victim / "retained"
    sentinel.write_text("outside\n")
    run = tmp_path / "run"
    run.mkdir()
    (run / "tries").symlink_to(outside, target_is_directory=True)
    artefacts = run / "tries" / "try-01" / "variant"

    with pytest.raises(RetainedPathUnsafeError) as raised:
        NixPromptVariantBuilder(FailingVariantRunner()).build(
            configuration,
            proposal,
            artefacts,
            run,
        )

    assert (raised.value, sentinel.read_text()) == (
        RetainedPathUnsafeError(artefacts),
        "outside\n",
    )


def test_prompt_patch_retains_parser_failure() -> None:
    with pytest.raises(PromptPatchFormatError) as raised:
        validate_prompt_patch("--- a/file\n+++ b/file\n@@ -1 +1 @@\nold\n")

    assert type(raised.value.cause) is UnidiffParseError


@pytest.mark.parametrize(
    ("endpoint", "expected"),
    [
        ("a/instructions/AGENTS.md", Path("instructions/AGENTS.md")),
        ("b/output-style/plain.md", Path("output-style/plain.md")),
    ],
)
def test_prompt_patch_path_strips_the_component_patch_removes(
    endpoint: str,
    expected: Path,
) -> None:
    assert prompt_patch_path(endpoint) == expected


def test_prompt_patch_path_rejects_an_endpoint_without_a_prefix() -> None:
    with pytest.raises(PromptPatchPrefixError) as raised:
        prompt_patch_path("instructions/AGENTS.md")

    assert raised.value == PromptPatchPrefixError(("instructions/AGENTS.md",))


def test_prompt_patch_accepts_the_declared_source_directories() -> None:
    patch = (
        "--- a/instructions/AGENTS.md\n"
        "+++ b/instructions/AGENTS.md\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
        "--- a/output-style/plain.md\n"
        "+++ b/output-style/plain.md\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    )

    assert validate_prompt_patch(patch) is None
