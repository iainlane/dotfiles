"""Read-only MCP capabilities for one candidate evaluation."""

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Annotated

import msgspec
from mcp.server.fastmcp import FastMCP
from pydantic import Field, JsonValue

from ..errors import ConformanceError
from ..protocols.claude import (
    CandidateAction,
    CandidateToolResult,
    CandidateToolUse,
)
from ..protocols.mcp import EvaluatorDescriptor, EvaluatorVerification
from .configuration import McpConfigurationFormatError
from .files import (
    McpDocumentReadError,
    list_files,
    list_workspace_files,
    read_page,
    read_text,
    relative_path,
    resolved_child,
)
from .models import (
    Action,
    ActionDetails,
    CandidateSummary,
    CandidateToolCall,
    CheckEvidence,
    CheckSummary,
    ControlledPrompt,
    Criterion,
    EvaluationBrief,
    FileListing,
    PromptDocument,
    SearchMatch,
    SearchResults,
    Task,
    TextPage,
    ToolResultAction,
    ToolUseAction,
)


@dataclass(eq=True)
class McpAccessRecordWriteError(ConformanceError):
    destination: Path
    cause: OSError

    def __str__(self) -> str:
        return f"MCP could not record a served tool call in {self.destination}: {self.cause}"


@dataclass(eq=True)
class McpUnknownCheckError(ConformanceError):
    name: str
    available: tuple[str, ...]

    def __str__(self) -> str:
        return f"unknown verification check {self.name!r}"


@dataclass(eq=True)
class McpUnknownActionError(ConformanceError):
    offset: int
    action_count: int

    def __str__(self) -> str:
        return f"candidate action offset {self.offset} is outside {self.action_count} actions"


@dataclass(eq=True)
class McpPromptFileLimitError(ConformanceError):
    root: Path
    limit: int

    def __str__(self) -> str:
        return f"controlled prompt {self.root} contains more than {self.limit} files"


PageOffset = Annotated[int, Field(ge=0)]
PageLimit = Annotated[int, Field(ge=1, le=20_000)]
ActionOffsets = Annotated[tuple[PageOffset, ...], Field(min_length=1, max_length=20)]

EVALUATION_BRIEF_TOOL = "get_evaluation_brief"

BRIEF_TEXT_LIMIT = 20_000
BRIEF_TOOL_CALL_LIMIT = 200
INDEX_INPUT_LIMIT = 2_000


class EvaluatorEvidence:
    """Provide evaluator evidence without exposing unrestricted host reads."""

    def __init__(self, configuration: EvaluatorDescriptor) -> None:
        self._configuration = configuration

    def record(self, tool: str) -> None:
        """Append one served tool so the backend can audit the judge's evidence."""

        destination = Path(self._configuration.access_record)
        try:
            with destination.open("a", encoding="utf-8") as stream:
                stream.write(f"{tool}\n")
        except OSError as error:
            raise McpAccessRecordWriteError(destination, error) from error

    def task(self) -> Task:
        return Task(
            kind=self._configuration.task_kind,
            text=read_text(Path(self._configuration.task)),
            criteria=tuple(
                Criterion(
                    identifier=criterion.identifier,
                    kind=criterion.kind,
                    requirement=criterion.requirement,
                )
                for criterion in self._configuration.criteria
            ),
        )

    def candidate_summary(self) -> CandidateSummary:
        repository = self._configuration.repository
        actions = self._actions()
        return CandidateSummary(
            response=read_text(Path(self._configuration.response)),
            repository_url=repository.url,
            base_revision=repository.base_revision,
            head_revision=repository.head_revision,
            status=repository.status,
            changed_files=repository.changed_files,
            action_count=len(actions),
            checks=tuple(check.name for check in self._configuration.verification),
        )

    def brief(self) -> EvaluationBrief:
        tool_calls = self._tool_calls()
        return EvaluationBrief(
            task=self.task(),
            candidate=self.candidate_summary(),
            patch=self.patch(0, BRIEF_TEXT_LIMIT),
            commits=self.commits(0, BRIEF_TEXT_LIMIT),
            checks=self.checks(),
            tool_calls=tool_calls[:BRIEF_TOOL_CALL_LIMIT],
            tool_calls_truncated=len(tool_calls) > BRIEF_TOOL_CALL_LIMIT,
        )

    def action_details(self, offsets: tuple[int, ...]) -> ActionDetails:
        actions = self._actions()
        for offset in offsets:
            if offset >= len(actions):
                raise McpUnknownActionError(offset, len(actions))
        return ActionDetails(
            actions=tuple(action(actions[offset]) for offset in offsets),
        )

    def patch(self, offset: int, limit: int) -> TextPage:
        return read_page(Path(self._configuration.repository.diff), offset, limit)

    def commits(self, offset: int, limit: int) -> TextPage:
        return read_page(Path(self._configuration.repository.commits), offset, limit)

    def checks(self) -> tuple[CheckSummary, ...]:
        return tuple(check_summary(check) for check in self._configuration.verification)

    def check(self, name: str, offset: int, limit: int) -> CheckEvidence:
        try:
            check = next(
                item for item in self._configuration.verification if item.name == name
            )
        except StopIteration as error:
            raise McpUnknownCheckError(
                name,
                tuple(item.name for item in self._configuration.verification),
            ) from error
        return CheckEvidence(
            check=check_summary(check),
            stdout=read_page(Path(check.stdout), offset, limit),
            stderr=read_page(Path(check.stderr), offset, limit),
        )

    def controlled_prompt(self) -> ControlledPrompt:
        root = Path(self._configuration.prompt_root)
        files, truncated = list_files(root, PurePosixPath(), 1_000)
        if truncated:
            raise McpPromptFileLimitError(root, 1_000)
        return ControlledPrompt(
            documents=tuple(
                PromptDocument(
                    path=path,
                    text=read_text(root / path),
                )
                for path in files
            )
        )

    def workspace_files(self, prefix: str, offset: int, limit: int) -> FileListing:
        root = Path(self._configuration.workspace)
        relative = relative_path(root, prefix)
        source = resolved_child(root, relative)
        files, next_offset = list_workspace_files(
            source, PurePosixPath(prefix), offset, limit
        )
        return FileListing(
            root=prefix or ".",
            offset=offset,
            next_offset=next_offset,
            files=files,
            truncated=next_offset is not None,
        )

    def workspace_documents(
        self, paths: tuple[str, ...], limit: int
    ) -> tuple[TextPage, ...]:
        root = Path(self._configuration.workspace)
        return tuple(
            read_page(
                resolved_child(root, relative_path(root, path)),
                0,
                limit,
                display_path=path,
            )
            for path in paths
        )

    def search_workspace(self, query: str, prefix: str, limit: int) -> SearchResults:
        root = Path(self._configuration.workspace)
        relative = relative_path(root, prefix)
        source = resolved_child(root, relative)
        matches: list[SearchMatch] = []
        paths, next_offset = list_workspace_files(
            source, PurePosixPath(prefix), 0, 10_000
        )
        for path in paths:
            candidate = resolved_child(root, relative_path(root, path))
            try:
                lines = candidate.read_text(errors="replace").splitlines()
            except OSError as error:
                raise McpDocumentReadError(candidate, error) from error
            for line_number, line in enumerate(lines, start=1):
                if query not in line:
                    continue
                matches.append(SearchMatch(path=path, line=line_number, text=line))
                if len(matches) == limit:
                    return SearchResults(
                        query=query, matches=tuple(matches), truncated=True
                    )
        return SearchResults(
            query=query,
            matches=tuple(matches),
            truncated=next_offset is not None,
        )

    def _actions(self) -> tuple[CandidateAction, ...]:
        source = Path(self._configuration.actions)
        try:
            return msgspec.json.decode(
                source.read_bytes(), type=tuple[CandidateAction, ...]
            )
        except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
            raise McpConfigurationFormatError(source, error) from error

    def _tool_calls(self) -> tuple[CandidateToolCall, ...]:
        actions = self._actions()
        results: dict[str, tuple[int, CandidateToolResult]] = {}
        for offset, value in enumerate(actions):
            match value:
                case CandidateToolResult(tool_use_id=identifier) if (
                    identifier is not None
                ):
                    results[identifier] = (offset, value)
                case _:
                    continue

        calls = []
        for offset, value in enumerate(actions):
            match value:
                case CandidateToolUse():
                    pass
                case _:
                    continue

            contents, truncated = bounded_action_value(value.input, INDEX_INPUT_LIMIT)
            result = results.get(value.id) if value.id is not None else None
            result_offset: int | None = None
            result_is_error: bool | None = None
            if result is not None:
                result_offset, result_action = result
                result_is_error = result_action.is_error

            calls.append(
                CandidateToolCall(
                    action_offset=offset,
                    result_offset=result_offset,
                    identifier=value.id,
                    name=value.name,
                    input=contents,
                    input_truncated=truncated,
                    result_is_error=result_is_error,
                )
            )
        return tuple(calls)


def create_evaluator_server(evidence: EvaluatorEvidence) -> FastMCP[None]:
    """Register the evaluator's schema-backed evidence tools."""

    server: FastMCP[None] = FastMCP(
        "prompt-conformance-evaluator",
        instructions=(
            "Use these read-only tools to inspect the complete task context, "
            "candidate work, checks, and controlled prompt."
        ),
    )

    @server.tool()
    def get_evaluation_brief() -> EvaluationBrief:
        """Return the task and the core outcome and process evidence in one result."""

        evidence.record(EVALUATION_BRIEF_TOOL)
        return evidence.brief()

    @server.tool()
    def get_candidate_action_details(offsets: ActionOffsets) -> ActionDetails:
        """Return exact payloads for selected offsets from the compact tool-call index."""

        evidence.record("get_candidate_action_details")
        return evidence.action_details(offsets)

    @server.tool()
    def get_patch(offset: PageOffset = 0, limit: PageLimit = 20_000) -> TextPage:
        """Return a page of the candidate's complete Git patch."""

        evidence.record("get_patch")
        return evidence.patch(offset, limit)

    @server.tool()
    def get_commits(offset: PageOffset = 0, limit: PageLimit = 20_000) -> TextPage:
        """Return a page of commits created after the fixture base revision."""

        evidence.record("get_commits")
        return evidence.commits(offset, limit)

    @server.tool()
    def get_check(
        name: str,
        offset: PageOffset = 0,
        limit: PageLimit = 20_000,
    ) -> CheckEvidence:
        """Return stdout and stderr for one named deterministic check."""

        evidence.record("get_check")
        return evidence.check(name, offset, limit)

    @server.tool()
    def get_controlled_prompt() -> ControlledPrompt:
        """Return every prompt rule, output style, setting, and manifest under test."""

        evidence.record("get_controlled_prompt")
        return evidence.controlled_prompt()

    @server.tool()
    def list_workspace_files(
        prefix: str = "",
        offset: PageOffset = 0,
        limit: Annotated[int, Field(ge=1, le=1_000)] = 200,
    ) -> FileListing:
        """List repository files below a relative directory."""

        evidence.record("list_workspace_files")
        return evidence.workspace_files(prefix, offset, limit)

    @server.tool()
    def read_workspace_files(
        paths: Annotated[tuple[str, ...], Field(min_length=1, max_length=20)],
        limit: PageLimit = 20_000,
    ) -> tuple[TextPage, ...]:
        """Read several repository files in one bounded request."""

        evidence.record("read_workspace_files")
        return evidence.workspace_documents(paths, limit)

    @server.tool()
    def search_workspace(
        query: str,
        prefix: str = "",
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
    ) -> SearchResults:
        """Find a literal string in repository text files below a directory."""

        evidence.record("search_workspace")
        return evidence.search_workspace(query, prefix, limit)

    return server


def action(value: CandidateAction) -> Action:
    """Convert the persisted action union to its structured tool representation."""

    match value:
        case CandidateToolUse():
            contents, truncated = bounded_action_value(value.input)
            return ToolUseAction(
                identifier=value.id,
                name=value.name,
                input=contents,
                truncated=truncated,
            )
        case CandidateToolResult():
            contents, truncated = bounded_action_value(value.content)
            return ToolResultAction(
                tool_use_id=value.tool_use_id,
                content=contents,
                is_error=value.is_error,
                truncated=truncated,
            )


def bounded_action_value(
    value: JsonValue, limit: int = 10_000
) -> tuple[JsonValue, bool]:
    """Keep one action from consuming an evaluator's complete context."""

    encoded = msgspec.json.encode(value)
    if len(encoded) <= limit:
        return value, False
    return encoded[:limit].decode(errors="replace"), True


def check_summary(value: EvaluatorVerification) -> CheckSummary:
    """Project one verification record into the evaluator's compact listing."""

    return CheckSummary(
        name=value.name,
        command=value.command,
        kind=value.kind,
        expected_return_code=value.expected_return_code,
        return_code=value.return_code,
        passed=value.return_code == value.expected_return_code,
    )
