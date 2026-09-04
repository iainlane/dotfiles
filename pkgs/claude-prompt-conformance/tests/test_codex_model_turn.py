import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from claude_prompt_conformance.agents.codex import codex_model_transport
from claude_prompt_conformance.agents.improver import (
    IMPROVER_ANGLES,
    CodexPromptImprover,
)
from claude_prompt_conformance.agents.judge import CodexJudge
from claude_prompt_conformance.mcp import write_configuration
from claude_prompt_conformance.models import (
    ClaudeConfiguration,
    CodexAgentConfiguration,
    CodexConfiguration,
    FailureOrigin,
    InstancePaths,
    IsolationConfiguration,
    JudgedCriterion,
    Judgement,
    JudgementSubject,
    PromptProposal,
    PromptVariantConfiguration,
    RuntimeConfiguration,
    VerificationKind,
    VerificationResult,
    WorkspaceEvidence,
)
from claude_prompt_conformance.platforms.codex import load_codex_host_configuration
from claude_prompt_conformance.platforms.direct import DirectProcessRunner
from claude_prompt_conformance.process import ProcessSupervisor
from claude_prompt_conformance.protocols.mcp import (
    CriterionOutcomeRecord,
    FixtureOutcomeRecord,
    ImproverDescriptor,
    SampleOutcomeRecord,
    VerificationOutcomeRecord,
)
from claude_prompt_conformance.protocols.schema import SchemaName, schema_document

from .codex_model_endpoint import (
    ModelTurn,
    ScriptedModelEndpoint,
    install_recording_transport,
)
from .codex_responses_protocol import (
    CODE_MODE_COMPLETED_STATUS,
    CODE_MODE_TOOLS,
    assistant_message,
    code_mode_call,
    mcp_tool_calls,
    mcp_tool_script,
    tooling_warnings,
    unusable_certificate_bundle,
)
from .helpers import (
    codex_identity,
    codex_refresh_transport,
    make_fixture,
    unsigned_access_token,
)

EVALUATION_BRIEF = "get_evaluation_brief"
IMPROVEMENT_OVERVIEW = "get_improvement_overview"
JUDGE_CALL = "judge-call"
IMPROVER_CALL = "improver-call"
CANDIDATE_RESPONSE = "I made the guard reject an empty argument.\n"
CODEX_ACCOUNT_ID = "account-1"


def required_program(name: str) -> str:
    """Locate one packaged program the endpoint tests drive for real."""

    program = shutil.which(name)
    if program is None:
        pytest.fail(f"the pinned {name} executable is required for endpoint tests")
    return program


def build_repository(root: Path, git: str) -> WorkspaceEvidence:
    """Commit a real change whose diff, log, and revisions become judge evidence."""

    workspace = root / "workspace"
    workspace.mkdir(parents=True)
    environment = {
        "PATH": os.environ["PATH"],
        "HOME": str(root),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
    }

    def run(*arguments: str) -> str:
        return subprocess.run(
            (git, *arguments),
            cwd=workspace,
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        ).stdout

    guard = workspace / "guard.sh"
    run("init", "--quiet", "--initial-branch=main")
    run("config", "user.email", "judge@example.invalid")
    run("config", "user.name", "Conformance")
    guard.write_text("#!/bin/sh\nexit 0\n")
    run("add", "guard.sh")
    run("commit", "--quiet", "--message", "Add the guard")
    base_revision = run("rev-parse", "HEAD").strip()
    guard.write_text('#!/bin/sh\ntest -n "$1" || exit 1\nexit 0\n')
    run("add", "guard.sh")
    run("commit", "--quiet", "--message", "Reject an empty argument")
    head_revision = run("rev-parse", "HEAD").strip()

    diff = root / "diff.patch"
    diff.write_text(run("diff", f"{base_revision}..{head_revision}"))
    commits = root / "commits.txt"
    commits.write_text(run("log", "--oneline", f"{base_revision}..{head_revision}"))
    return WorkspaceEvidence(
        workspace=workspace,
        base_revision=base_revision,
        head_revision=head_revision,
        status=run("status", "--porcelain").strip(),
        diff=diff,
        commits=commits,
        changed_files=("guard.sh",),
    )


def build_verification(root: Path) -> tuple[VerificationResult, ...]:
    """Record one deterministic check whose output the evaluator can read."""

    stdout = root / "check.stdout"
    stdout.write_text("guard.sh rejects an empty argument\n")
    stderr = root / "check.stderr"
    stderr.write_text("")
    return (
        VerificationResult(
            "check",
            ("check",),
            VerificationKind.GATE,
            0,
            0,
            stdout,
            stderr,
        ),
    )


def build_instance(root: Path) -> InstancePaths:
    """Create every instance directory a Codex role writes to."""

    instance = InstancePaths(
        root=root,
        workspace=root / "workspace",
        control=root / "control",
        candidate_state=root / "candidate-state",
        candidate_cache=root / "candidate-cache",
        candidate_temp=root / "candidate-temp",
        judge_state=root / "judge-state",
        judge_cache=root / "judge-cache",
        judge_temp=root / "judge-temp",
    )
    for path in instance.__dict__.values():
        path.mkdir(parents=True, exist_ok=True)
    return instance


def build_configuration(
    root: Path,
    codex: str,
    mcp_program: str,
    agent: CodexAgentConfiguration,
) -> RuntimeConfiguration:
    """Assemble the runtime configuration a Codex role needs, without Nix."""

    root.mkdir(parents=True)
    schema = root / "judgement.json"
    schema.write_text(json.dumps(schema_document(SchemaName.JUDGEMENT)))
    proposal_schema = root / "proposal.json"
    proposal_schema.write_text(json.dumps(schema_document(SchemaName.PROPOSAL)))
    certificates = unusable_certificate_bundle(root / "ca-bundle.crt")
    context = root / "prompt-context"
    context.mkdir()
    (context / "rules.md").write_text("Report exactly what the evidence shows.\n")
    source = root / "prompt-source"
    source.mkdir()
    (source / "instructions").mkdir()
    (source / "instructions" / "AGENTS.md").write_text("Be precise.\n")
    return RuntimeConfiguration(
        fixture_manifest=root / "fixtures.json",
        run_metadata=root / "run.json",
        prompt_context=context,
        candidate_context=context,
        workspace_overlay=root / "overlay",
        git_program="git",
        claude=ClaudeConfiguration(
            program="claude",
            shell="sh",
            settings=root / "settings.json",
            model="claude-opus-5",
            effort="medium",
            api_budget_usd="0.75",
            output_style="plain-technical-prose",
            oauth_token_url="https://claude.invalid/oauth/token",
            oauth_client_id="claude-client",
        ),
        codex=CodexConfiguration(
            program=codex,
            mcp_program=mcp_program,
            judge=agent,
            improver=agent,
            schema=schema,
            proposal_schema=proposal_schema,
            tls_certificate_bundle=certificates,
            oauth_token_url="https://codex.invalid/oauth/token",
            oauth_client_id="codex-client",
        ),
        isolation=IsolationConfiguration("direct", None),
        variant=PromptVariantConfiguration(
            nix_program="nix",
            nixpkgs=root,
            expression=root / "variant.nix",
            prompt_environment=root / "prompt-environment.nix",
            prompt_source=source,
        ),
        source=root / "configuration.json",
    )


def judgement_response() -> str:
    """Return the schema-valid judgement the scripted model produces."""

    return json.dumps(
        {
            "criteria": [
                {
                    "id": "works",
                    "passed": True,
                    "reason": "The guard rejects an empty argument.",
                    "evidence": ["guard.sh"],
                }
            ],
            "failureOrigin": "none",
            "summary": "The change satisfies the criterion.",
            "recommendation": "No changes are needed.",
            "counterfactual": "",
            "correctedResponse": "",
            "promptObservations": [],
        }
    )


def proposal_response() -> str:
    """Return the schema-valid proposal the scripted model produces."""

    return json.dumps(
        {
            "noChange": True,
            "title": "Keep the instructions unchanged",
            "observations": ["Every working sample passed its criterion."],
            "change": "",
            "reasoning": "The evidence attributes no failure to the prompt.",
            "risks": [],
            "patch": "",
        }
    )


def improver_evidence(root: Path, context: Path) -> Path:
    """Describe one passing sample as the evidence a fresh improver receives."""

    return write_configuration(
        root,
        root / "improver-mcp.json",
        ImproverDescriptor(
            prompt_root=str(context),
            working=(
                SampleOutcomeRecord(
                    sample=0,
                    outcomes=(
                        FixtureOutcomeRecord(
                            fixture="example",
                            status="passed",
                            error_type=None,
                            criteria=(
                                CriterionOutcomeRecord(
                                    identifier="works",
                                    passed=True,
                                    reason="The guard rejects an empty argument.",
                                    evidence=("guard.sh",),
                                ),
                            ),
                            checks=(
                                VerificationOutcomeRecord(
                                    name="check",
                                    command=("check",),
                                    kind="gate",
                                    expected_return_code=0,
                                    return_code=0,
                                    passed=True,
                                    flaky=False,
                                    stdout="ok\n",
                                    stdout_truncated=False,
                                    stderr="",
                                    stderr_truncated=False,
                                ),
                            ),
                            failure_origin="none",
                            summary="The change satisfies the criterion.",
                            recommendation="No changes are needed.",
                            prompt_observations=(),
                        ),
                    ),
                ),
            ),
        ),
    )


def model_turns(call_id: str, tool: str, response: str) -> tuple[ModelTurn, ...]:
    """Script one code-mode evidence request followed by one structured answer."""

    return (
        (code_mode_call(call_id, mcp_tool_script("conformance", tool)),),
        (assistant_message("final", response),),
    )


@pytest.mark.endpoint_integration
@pytest.mark.timeout(180)
def test_codex_judge_reads_its_evidence_through_code_mode(tmp_path: Path) -> None:
    """Drive the packaged Codex judge through a scripted model turn end to end."""

    codex = required_program("codex")
    mcp_program = required_program("claude-prompt-conformance-mcp")
    git = required_program("git")

    evidence = build_repository(tmp_path / "evidence", git)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    trace = artefacts / "trace.json"
    trace.write_text("[]")
    subject = JudgementSubject(
        name="candidate",
        workspace=evidence.workspace,
        response=CANDIDATE_RESPONSE,
        trace=trace,
        evidence=evidence,
        verification=build_verification(tmp_path / "evidence"),
    )
    requests = tmp_path / "mcp-requests.jsonl"
    responses = tmp_path / "mcp-responses.jsonl"
    recorder = install_recording_transport(
        sys.executable,
        mcp_program,
        tmp_path / "recording-mcp",
        requests,
        responses,
    )
    agent = CodexAgentConfiguration("gpt-5.6-terra", "high", "fast", "low", 272000)
    configuration = build_configuration(tmp_path / "runtime", codex, recorder, agent)
    fixture = make_fixture(tmp_path / "fixtures", environment_path=os.environ["PATH"])
    instance = build_instance(tmp_path / "instance")
    token = unsigned_access_token()
    identity = codex_identity(
        tmp_path / "codex-home",
        token,
        CODEX_ACCOUNT_ID,
        codex_refresh_transport(token),
    )

    with ScriptedModelEndpoint(
        model_turns(JUDGE_CALL, EVALUATION_BRIEF, judgement_response())
    ) as endpoint:
        judgement = CodexJudge(
            configuration,
            DirectProcessRunner(ProcessSupervisor()),
            identity,
            load_codex_host_configuration(),
            codex_model_transport(endpoint.base_url),
        ).assess(fixture, subject, instance, artefacts)
        requested = endpoint.requests

    transcript = (artefacts / "codex-candidate-events.jsonl").read_bytes()
    brief = "".join(requested[1].tool_results(JUDGE_CALL))
    assert (
        judgement,
        Judgement.from_file(artefacts / "judgement-candidate.json"),
        mcp_tool_calls(requests.read_bytes()),
        endpoint.unexpected_paths,
        len(requested),
        requested[0].model,
        requested[0].tool_names,
        brief.startswith(CODE_MODE_COMPLETED_STATUS),
        evidence.head_revision in brief,
        tooling_warnings(transcript),
    ) == (
        Judgement(
            criteria=(
                JudgedCriterion(
                    identifier="works",
                    passed=True,
                    reason="The guard rejects an empty argument.",
                    evidence=("guard.sh",),
                ),
            ),
            failure_origin=FailureOrigin.NONE,
            summary="The change satisfies the criterion.",
            recommendation="No changes are needed.",
            counterfactual="",
            corrected_response="",
            prompt_observations=(),
        ),
        judgement,
        (EVALUATION_BRIEF,),
        (),
        2,
        agent.model,
        CODE_MODE_TOOLS,
        True,
        True,
        (),
    )


@pytest.mark.endpoint_integration
@pytest.mark.timeout(180)
def test_codex_improver_reads_its_evidence_through_code_mode(tmp_path: Path) -> None:
    """Drive the packaged Codex improver through the same scripted model turn."""

    codex = required_program("codex")
    mcp_program = required_program("claude-prompt-conformance-mcp")

    requests = tmp_path / "mcp-requests.jsonl"
    responses = tmp_path / "mcp-responses.jsonl"
    recorder = install_recording_transport(
        sys.executable,
        mcp_program,
        tmp_path / "recording-mcp",
        requests,
        responses,
    )
    agent = CodexAgentConfiguration("gpt-5.6-sol", "high", "fast", "low", 272000)
    configuration = build_configuration(tmp_path / "runtime", codex, recorder, agent)
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    instance = build_instance(tmp_path / "instance")
    token = unsigned_access_token()
    identity = codex_identity(
        tmp_path / "codex-home",
        token,
        CODEX_ACCOUNT_ID,
        codex_refresh_transport(token),
    )
    evidence = improver_evidence(artefacts, configuration.prompt_context)

    with ScriptedModelEndpoint(
        model_turns(IMPROVER_CALL, IMPROVEMENT_OVERVIEW, proposal_response())
    ) as endpoint:
        proposal = CodexPromptImprover(
            configuration,
            DirectProcessRunner(ProcessSupervisor()),
            identity,
            load_codex_host_configuration(),
            codex_model_transport(endpoint.base_url),
        ).propose(
            configuration,
            evidence,
            os.environ["PATH"],
            instance,
            artefacts,
            IMPROVER_ANGLES[0],
        )
        requested = endpoint.requests

    transcript = (artefacts / "prompt-improver-events.jsonl").read_bytes()
    overview = "".join(requested[1].tool_results(IMPROVER_CALL))
    assert (
        proposal,
        PromptProposal.from_file(artefacts / "prompt-proposal.json"),
        mcp_tool_calls(requests.read_bytes()),
        endpoint.unexpected_paths,
        len(requested),
        requested[0].model,
        requested[0].tool_names,
        overview.startswith(CODE_MODE_COMPLETED_STATUS),
        "works" in overview,
        tooling_warnings(transcript),
    ) == (
        PromptProposal(
            no_change=True,
            title="Keep the instructions unchanged",
            observations=("Every working sample passed its criterion.",),
            change="",
            reasoning="The evidence attributes no failure to the prompt.",
            risks=(),
            patch="",
        ),
        proposal,
        (IMPROVEMENT_OVERVIEW,),
        (),
        2,
        agent.model,
        CODE_MODE_TOOLS,
        True,
        True,
        (),
    )
