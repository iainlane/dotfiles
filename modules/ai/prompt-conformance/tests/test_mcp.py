import asyncio
from collections.abc import Sequence
from pathlib import Path
from typing import overload

import msgspec
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from claude_prompt_conformance.mcp import (
    create_server,
    load_configuration,
    write_configuration,
)
from claude_prompt_conformance.mcp.evaluator import (
    EvaluatorEvidence,
    McpUnknownActionError,
    action,
)
from claude_prompt_conformance.mcp.files import McpPathOutsideRootError
from claude_prompt_conformance.mcp.improver import ImproverEvidence
from claude_prompt_conformance.mcp.models import (
    ActionDetails,
    CandidateSummary,
    CandidateToolCall,
    CheckSummary,
    ControlledPrompt,
    Criterion,
    CriterionOutcome,
    CriterionScoreSummary,
    EvaluationBrief,
    FailureDetail,
    FailureListing,
    FailureReference,
    FileListing,
    ImprovementOverview,
    PromptDocument,
    SearchMatch,
    SearchResults,
    Task,
    TextPage,
    ToolResultAction,
    ToolUseAction,
    VerificationOutcome,
    WorkingExamplesSummary,
)
from claude_prompt_conformance.mcp.server import main
from claude_prompt_conformance.protocols.claude import (
    CandidateToolResult,
    CandidateToolUse,
)
from claude_prompt_conformance.protocols.configuration import CriterionInput
from claude_prompt_conformance.protocols.mcp import (
    CriterionOutcomeRecord,
    EvaluatorDescriptor,
    EvaluatorRepository,
    EvaluatorVerification,
    FixtureOutcomeRecord,
    ImproverDescriptor,
    SampleOutcomeRecord,
    VerificationOutcomeRecord,
)


class InterruptingArguments(Sequence[str]):
    @overload
    def __getitem__(self, index: int) -> str: ...
    @overload
    def __getitem__(self, index: slice) -> Sequence[str]: ...
    def __getitem__(self, index: int | slice) -> str | Sequence[str]:
        raise KeyboardInterrupt

    def __len__(self) -> int:
        return 1


def test_mcp_server_returns_the_conventional_status_for_sigint() -> None:
    assert main(InterruptingArguments()) == 130


def evaluator_configuration(tmp_path: Path) -> EvaluatorDescriptor:
    task = tmp_path / "task.txt"
    task.write_text("Diagnose and repair the defect.\n")
    response = tmp_path / "response.md"
    response.write_text("Implemented and checked.\n")
    actions = tmp_path / "actions.json"
    actions.write_bytes(
        msgspec.json.encode(
            (
                CandidateToolUse("call-1", "Read", {"file_path": "src/main.py"}),
                CandidateToolResult("call-1", "old = True", False),
            )
        )
    )
    workspace = tmp_path / "workspace"
    (workspace / "src").mkdir(parents=True)
    (workspace / "src" / "main.py").write_text("fixed = True\n")
    prompt = tmp_path / "prompt"
    (prompt / "rules").mkdir(parents=True)
    (prompt / "rules" / "global.md").write_text("Use clear language.\n")
    patch = tmp_path / "diff.patch"
    patch.write_text("diff --git a/src/main.py b/src/main.py\n")
    commits = tmp_path / "commits.txt"
    commits.write_text("commit abc\n")
    stdout = tmp_path / "check.stdout"
    stdout.write_text("ok\n")
    stderr = tmp_path / "check.stderr"
    stderr.write_text("")
    return EvaluatorDescriptor(
        task=str(task),
        task_kind="author",
        criteria=(CriterionInput("works", "outcome", "The repair works.", True),),
        prompt_root=str(prompt),
        response=str(response),
        actions=str(actions),
        workspace=str(workspace),
        repository=EvaluatorRepository(
            url="https://example.invalid/repository.git",
            base_revision="base",
            head_revision="head",
            status="",
            changed_files=("src/main.py",),
            diff=str(patch),
            commits=str(commits),
        ),
        verification=(
            EvaluatorVerification(
                name="unit tests",
                command=("pytest",),
                kind="gate",
                expected_return_code=0,
                return_code=0,
                stdout=str(stdout),
                stderr=str(stderr),
            ),
        ),
        access_record=str(tmp_path / "tool-calls.txt"),
    )


def improver_configuration(tmp_path: Path) -> ImproverDescriptor:
    prompt = tmp_path / "prompt-source"
    (prompt / "instructions").mkdir(parents=True)
    (prompt / "instructions" / "AGENTS.md").write_text("Be precise.\n")
    (prompt / "output-style").mkdir()
    (prompt / "output-style" / "plain.md").write_text("Write plainly.\n")
    reserved = prompt / "prompt-conformance" / "fixtures" / "reserved"
    reserved.mkdir(parents=True)
    (reserved / "task.txt").write_text("Hidden reserved task.\n")
    failed = FixtureOutcomeRecord(
        fixture="author-case",
        status="failed",
        error_type=None,
        criteria=(
            CriterionOutcomeRecord(
                "verification",
                False,
                "The final response contradicted the recorded check.",
                ("check.stdout", "response.md"),
            ),
        ),
        checks=(
            VerificationOutcomeRecord(
                name="unit tests",
                command=("pytest",),
                kind="gate",
                expected_return_code=0,
                return_code=1,
                passed=False,
                flaky=False,
                stdout="1 failed\n",
                stdout_truncated=False,
                stderr="",
                stderr_truncated=False,
            ),
        ),
        failure_origin="prompt",
        summary="The work was correct but the handoff was inaccurate.",
        recommendation="Report recorded checks exactly.",
        prompt_observations=("The prompt does not connect evidence to the handoff.",),
    )
    passed = FixtureOutcomeRecord(
        fixture="review-case",
        status="passed",
        error_type=None,
        criteria=(
            CriterionOutcomeRecord("findings", True, "Found the defect.", ("review",)),
        ),
        checks=(),
        failure_origin="none",
        summary="Complete review.",
        recommendation="No change.",
        prompt_observations=(),
    )
    return ImproverDescriptor(
        prompt_root=str(prompt),
        working=(SampleOutcomeRecord(1, (failed, passed)),),
    )


def test_evaluator_tools_have_complete_schemas_and_structured_results(
    tmp_path: Path,
) -> None:
    configuration = evaluator_configuration(tmp_path)
    path = write_configuration(tmp_path, tmp_path / "evaluator.json", configuration)
    server = create_server(load_configuration(path))

    tools = asyncio.run(server.list_tools())
    _, brief = asyncio.run(server.call_tool("get_evaluation_brief", {}))

    assert (
        load_configuration(path),
        tuple(
            (
                tool.name,
                tuple(tool.inputSchema.get("required", ())),
                tool.outputSchema is not None,
            )
            for tool in tools
        ),
        brief,
    ) == (
        configuration,
        (
            ("get_evaluation_brief", (), True),
            ("get_candidate_action_details", ("offsets",), True),
            ("get_patch", (), True),
            ("get_commits", (), True),
            ("get_check", ("name",), True),
            ("get_controlled_prompt", (), True),
            ("list_workspace_files", (), True),
            ("read_workspace_files", ("paths",), True),
            ("search_workspace", ("query",), True),
        ),
        {
            "task": {
                "kind": "author",
                "text": "Diagnose and repair the defect.\n",
                "criteria": [
                    {
                        "identifier": "works",
                        "kind": "outcome",
                        "requirement": "The repair works.",
                    }
                ],
            },
            "candidate": {
                "response": "Implemented and checked.\n",
                "repository_url": "https://example.invalid/repository.git",
                "base_revision": "base",
                "head_revision": "head",
                "status": "",
                "changed_files": ["src/main.py"],
                "action_count": 2,
                "checks": ["unit tests"],
            },
            "patch": {
                "path": "diff.patch",
                "offset": 0,
                "next_offset": None,
                "text": "diff --git a/src/main.py b/src/main.py\n",
            },
            "commits": {
                "path": "commits.txt",
                "offset": 0,
                "next_offset": None,
                "text": "commit abc\n",
            },
            "checks": [
                {
                    "name": "unit tests",
                    "command": ["pytest"],
                    "kind": "gate",
                    "expected_return_code": 0,
                    "return_code": 0,
                    "passed": True,
                }
            ],
            "tool_calls": [
                {
                    "action_offset": 0,
                    "result_offset": 1,
                    "identifier": "call-1",
                    "name": "Read",
                    "input": {"file_path": "src/main.py"},
                    "input_truncated": False,
                    "result_is_error": False,
                }
            ],
            "tool_calls_truncated": False,
        },
    )


def test_evaluator_provider_returns_complete_paged_evidence(tmp_path: Path) -> None:
    evidence = EvaluatorEvidence(evaluator_configuration(tmp_path))

    assert (
        evidence.brief(),
        evidence.action_details((0, 1)),
        evidence.controlled_prompt(),
        evidence.workspace_files("src", 0, 20),
        evidence.workspace_documents(("src/main.py",), 20_000),
        evidence.search_workspace("fixed", "src", 20),
    ) == (
        EvaluationBrief(
            task=Task(
                kind="author",
                text="Diagnose and repair the defect.\n",
                criteria=(
                    Criterion(
                        identifier="works",
                        kind="outcome",
                        requirement="The repair works.",
                    ),
                ),
            ),
            candidate=CandidateSummary(
                response="Implemented and checked.\n",
                repository_url="https://example.invalid/repository.git",
                base_revision="base",
                head_revision="head",
                status="",
                changed_files=("src/main.py",),
                action_count=2,
                checks=("unit tests",),
            ),
            patch=TextPage(
                path="diff.patch",
                offset=0,
                next_offset=None,
                text="diff --git a/src/main.py b/src/main.py\n",
            ),
            commits=TextPage(
                path="commits.txt",
                offset=0,
                next_offset=None,
                text="commit abc\n",
            ),
            checks=(
                CheckSummary(
                    name="unit tests",
                    command=("pytest",),
                    kind="gate",
                    expected_return_code=0,
                    return_code=0,
                    passed=True,
                ),
            ),
            tool_calls=(
                CandidateToolCall(
                    action_offset=0,
                    result_offset=1,
                    identifier="call-1",
                    name="Read",
                    input={"file_path": "src/main.py"},
                    input_truncated=False,
                    result_is_error=False,
                ),
            ),
            tool_calls_truncated=False,
        ),
        ActionDetails(
            actions=(
                ToolUseAction(
                    identifier="call-1",
                    name="Read",
                    input={"file_path": "src/main.py"},
                    truncated=False,
                ),
                ToolResultAction(
                    tool_use_id="call-1",
                    content="old = True",
                    is_error=False,
                    truncated=False,
                ),
            ),
        ),
        ControlledPrompt(
            documents=(
                PromptDocument(
                    path="rules/global.md",
                    text="Use clear language.\n",
                ),
            ),
        ),
        FileListing(
            root="src",
            offset=0,
            next_offset=None,
            files=("src/main.py",),
            truncated=False,
        ),
        (
            TextPage(
                path="src/main.py",
                offset=0,
                next_offset=None,
                text="fixed = True\n",
            ),
        ),
        SearchResults(
            query="fixed",
            matches=(SearchMatch(path="src/main.py", line=1, text="fixed = True"),),
            truncated=False,
        ),
    )

    with pytest.raises(McpPathOutsideRootError) as raised:
        evidence.workspace_documents(("../secret",), 20)

    assert raised.value == McpPathOutsideRootError(tmp_path / "workspace", "../secret")


def test_evaluator_bounds_individual_action_payloads() -> None:
    value = "x" * 20_000
    encoded = msgspec.json.encode(value)

    assert action(CandidateToolResult("call-1", value, False)) == ToolResultAction(
        tool_use_id="call-1",
        content=encoded[:10_000].decode(),
        is_error=False,
        truncated=True,
    )


def test_evaluation_brief_indexes_actions_without_embedding_tool_results(
    tmp_path: Path,
) -> None:
    configuration = evaluator_configuration(tmp_path)
    actions = Path(configuration.actions)
    actions.write_bytes(
        msgspec.json.encode(
            (
                CandidateToolUse(
                    "call-1",
                    "Bash",
                    {"command": "pytest", "description": "Run tests"},
                ),
                CandidateToolResult("call-1", "x" * 50_000, False),
            )
        )
    )
    evidence = EvaluatorEvidence(configuration)

    assert (
        evidence.brief().tool_calls,
        evidence.action_details((1,)),
    ) == (
        (
            CandidateToolCall(
                action_offset=0,
                result_offset=1,
                identifier="call-1",
                name="Bash",
                input={"command": "pytest", "description": "Run tests"},
                input_truncated=False,
                result_is_error=False,
            ),
        ),
        ActionDetails(
            actions=(
                ToolResultAction(
                    tool_use_id="call-1",
                    content=msgspec.json.encode("x" * 50_000)[:10_000].decode(),
                    is_error=False,
                    truncated=True,
                ),
            ),
        ),
    )

    with pytest.raises(McpUnknownActionError) as raised:
        evidence.action_details((2,))

    assert raised.value == McpUnknownActionError(2, 2)


def test_workspace_discovery_pages_source_files_and_ignores_prompt_links(
    tmp_path: Path,
) -> None:
    configuration = evaluator_configuration(tmp_path)
    workspace = Path(configuration.workspace)
    (workspace / "src" / "second.py").write_text("second = True\n")
    (workspace / "src" / "third.py").write_text("third = True\n")
    (workspace / ".claude").symlink_to(Path(configuration.prompt_root))
    evidence = EvaluatorEvidence(configuration)

    assert (
        evidence.workspace_files("src", 0, 2),
        evidence.workspace_files("src", 2, 2),
        evidence.search_workspace("fixed", "", 20),
    ) == (
        FileListing(
            root="src",
            offset=0,
            next_offset=2,
            files=("src/main.py", "src/second.py"),
            truncated=True,
        ),
        FileListing(
            root="src",
            offset=2,
            next_offset=None,
            files=("src/third.py",),
            truncated=False,
        ),
        SearchResults(
            query="fixed",
            matches=(SearchMatch(path="src/main.py", line=1, text="fixed = True"),),
            truncated=False,
        ),
    )


def test_schema_validation_rejects_invalid_tool_arguments(tmp_path: Path) -> None:
    server = create_server(evaluator_configuration(tmp_path))

    with pytest.raises(ToolError):
        asyncio.run(server.call_tool("get_patch", {"limit": 0}))


def test_improver_capabilities_expose_failures_selectively(tmp_path: Path) -> None:
    configuration = improver_configuration(tmp_path)
    path = write_configuration(tmp_path, tmp_path / "improver.json", configuration)
    loaded = load_configuration(path)
    assert isinstance(loaded, ImproverDescriptor)
    evidence = ImproverEvidence(loaded)
    server = create_server(loaded)

    assert (
        loaded,
        tuple(tool.name for tool in asyncio.run(server.list_tools())),
        evidence.overview(),
        evidence.failures(),
        evidence.failure(1, "author-case"),
        evidence.prompt_files(),
        evidence.prompt_file("output-style/plain.md", 0, 20_000),
    ) == (
        configuration,
        (
            "get_improvement_overview",
            "list_failures",
            "get_failure",
            "list_prompt_files",
            "read_prompt_file",
        ),
        ImprovementOverview(
            working=WorkingExamplesSummary(
                samples=1,
                outcomes=2,
                passed=1,
                failed=1,
                invalid=0,
            ),
            scores=(
                CriterionScoreSummary(
                    fixture="author-case",
                    criterion="verification",
                    passed=0,
                    total=1,
                ),
                CriterionScoreSummary(
                    fixture="review-case",
                    criterion="findings",
                    passed=1,
                    total=1,
                ),
            ),
        ),
        FailureListing(
            failures=(
                FailureReference(
                    sample=1,
                    fixture="author-case",
                    status="failed",
                    failed_criteria=("verification",),
                    failed_checks=("unit tests",),
                ),
            )
        ),
        FailureDetail(
            sample=1,
            fixture="author-case",
            status="failed",
            error_type=None,
            criteria=(
                CriterionOutcome(
                    identifier="verification",
                    passed=False,
                    reason="The final response contradicted the recorded check.",
                    evidence=("check.stdout", "response.md"),
                ),
            ),
            checks=(
                VerificationOutcome(
                    name="unit tests",
                    command=("pytest",),
                    kind="gate",
                    expected_return_code=0,
                    return_code=1,
                    passed=False,
                    flaky=False,
                    stdout="1 failed\n",
                    stdout_truncated=False,
                    stderr="",
                    stderr_truncated=False,
                ),
            ),
            failure_origin="prompt",
            summary="The work was correct but the handoff was inaccurate.",
            recommendation="Report recorded checks exactly.",
            prompt_observations=(
                "The prompt does not connect evidence to the handoff.",
            ),
        ),
        FileListing(
            root="prompt-source",
            offset=0,
            next_offset=None,
            files=("instructions/AGENTS.md", "output-style/plain.md"),
            truncated=False,
        ),
        TextPage(
            path="output-style/plain.md",
            offset=0,
            next_offset=None,
            text="Write plainly.\n",
        ),
    )

    with pytest.raises(McpPathOutsideRootError) as raised:
        evidence.prompt_file(
            "prompt-conformance/fixtures/reserved/task.txt",
            0,
            20_000,
        )

    assert raised.value == McpPathOutsideRootError(
        Path(configuration.prompt_root),
        "prompt-conformance/fixtures/reserved/task.txt",
    )
