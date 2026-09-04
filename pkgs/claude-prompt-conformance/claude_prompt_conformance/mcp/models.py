"""Schema-backed values returned by conformance MCP tools."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, JsonValue


class Model(BaseModel):
    """Immutable base for values exposed through MCP structured content."""

    model_config = ConfigDict(frozen=True)


class Criterion(Model):
    identifier: str
    kind: str
    requirement: str


class Task(Model):
    kind: str
    text: str
    criteria: tuple[Criterion, ...]


class CandidateSummary(Model):
    response: str
    repository_url: str
    base_revision: str
    head_revision: str
    status: str
    changed_files: tuple[str, ...]
    action_count: int
    checks: tuple[str, ...]


class TextPage(Model):
    path: str
    offset: int
    next_offset: int | None
    text: str


class FileListing(Model):
    root: str
    offset: int
    next_offset: int | None
    files: tuple[str, ...]
    truncated: bool


class ToolUseAction(Model):
    type: Literal["tool_use"] = "tool_use"
    identifier: str | None
    name: str | None
    input: JsonValue
    truncated: bool


class ToolResultAction(Model):
    type: Literal["tool_result"] = "tool_result"
    tool_use_id: str | None
    content: JsonValue
    is_error: bool
    truncated: bool


Action = ToolUseAction | ToolResultAction


class ActionDetails(Model):
    actions: tuple[Action, ...]


class CheckSummary(Model):
    name: str
    command: tuple[str, ...]
    kind: str
    expected_return_code: int
    return_code: int
    passed: bool


class CheckEvidence(Model):
    check: CheckSummary
    stdout: TextPage
    stderr: TextPage


class CandidateToolCall(Model):
    action_offset: int
    result_offset: int | None
    identifier: str | None
    name: str | None
    input: JsonValue
    input_truncated: bool
    result_is_error: bool | None


class EvaluationBrief(Model):
    task: Task
    candidate: CandidateSummary
    patch: TextPage
    commits: TextPage
    checks: tuple[CheckSummary, ...]
    tool_calls: tuple[CandidateToolCall, ...]
    tool_calls_truncated: bool


class PromptDocument(Model):
    path: str
    text: str


class ControlledPrompt(Model):
    documents: tuple[PromptDocument, ...]


class SearchMatch(Model):
    path: str
    line: int
    text: str


class SearchResults(Model):
    query: str
    matches: tuple[SearchMatch, ...]
    truncated: bool


class WorkingExamplesSummary(Model):
    samples: int
    outcomes: int
    passed: int
    failed: int
    invalid: int


class CriterionScoreSummary(Model):
    fixture: str
    criterion: str
    passed: int
    total: int


class ImprovementOverview(Model):
    working: WorkingExamplesSummary
    scores: tuple[CriterionScoreSummary, ...]


class FailureReference(Model):
    sample: int
    fixture: str
    status: str
    failed_criteria: tuple[str, ...]
    failed_checks: tuple[str, ...]


class FailureListing(Model):
    failures: tuple[FailureReference, ...]


class CriterionOutcome(Model):
    identifier: str
    passed: bool
    reason: str
    evidence: tuple[str, ...]


class VerificationOutcome(Model):
    name: str
    command: tuple[str, ...]
    kind: str
    expected_return_code: int
    return_code: int
    passed: bool
    flaky: bool
    stdout: str
    stdout_truncated: bool
    stderr: str
    stderr_truncated: bool


class FailureDetail(Model):
    sample: int
    fixture: str
    status: str
    error_type: str | None
    criteria: tuple[CriterionOutcome, ...]
    checks: tuple[VerificationOutcome, ...]
    failure_origin: str | None
    summary: str | None
    recommendation: str | None
    prompt_observations: tuple[str, ...]
