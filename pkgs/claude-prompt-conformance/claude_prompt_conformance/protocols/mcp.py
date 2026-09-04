"""Instance descriptors consumed by the evaluator and improver MCP servers."""

import msgspec

from .configuration import CriterionInput


class EvaluatorRepository(msgspec.Struct, frozen=True, rename="camel"):
    url: str
    base_revision: str
    head_revision: str
    status: str
    changed_files: tuple[str, ...]
    diff: str
    commits: str


class EvaluatorVerification(msgspec.Struct, frozen=True, rename="camel"):
    name: str
    command: tuple[str, ...]
    kind: str
    expected_return_code: int
    return_code: int
    stdout: str
    stderr: str


class EvaluatorDescriptor(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    tag="evaluator",
    tag_field="role",
):
    task: str
    task_kind: str
    criteria: tuple[CriterionInput, ...]
    prompt_root: str
    response: str
    actions: str
    workspace: str
    repository: EvaluatorRepository
    verification: tuple[EvaluatorVerification, ...]
    access_record: str


class CriterionOutcomeRecord(msgspec.Struct, frozen=True, rename="camel"):
    identifier: str = msgspec.field(name="id")
    passed: bool
    reason: str
    evidence: tuple[str, ...]


class VerificationOutcomeRecord(msgspec.Struct, frozen=True, rename="camel"):
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


class FixtureOutcomeRecord(msgspec.Struct, frozen=True, rename="camel"):
    fixture: str
    status: str
    error_type: str | None
    criteria: tuple[CriterionOutcomeRecord, ...]
    checks: tuple[VerificationOutcomeRecord, ...]
    failure_origin: str | None
    summary: str | None
    recommendation: str | None
    prompt_observations: tuple[str, ...]


class SampleOutcomeRecord(msgspec.Struct, frozen=True):
    sample: int
    outcomes: tuple[FixtureOutcomeRecord, ...]


class ImproverDescriptor(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    tag="improver",
    tag_field="role",
):
    prompt_root: str
    working: tuple[SampleOutcomeRecord, ...]


McpDescriptor = EvaluatorDescriptor | ImproverDescriptor
