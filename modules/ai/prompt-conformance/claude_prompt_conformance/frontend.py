import json
import threading
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, TextIO

import msgspec
from rich.console import Console, Group
from rich.markdown import Markdown
from rich.panel import Panel
from rich.prompt import Prompt
from rich.rule import Rule
from rich.syntax import Syntax
from rich.table import Table
from rich.text import Text

from .errors import ConformanceError
from .models import (
    Event,
    Fixture,
    ImprovementAborted,
    ImprovementFinished,
    SuiteFinished,
    SuiteInterrupted,
    TestFinished,
    TestStatus,
)
from .progress import TaskRun
from .task_frontend import JsonTaskView, RichTaskView


@dataclass(eq=True)
class ResultPresentationUnavailableError(ConformanceError):
    fixture: str

    def __str__(self) -> str:
        return f"fixture {self.fixture!r} has no presentable model result"


@dataclass(eq=True)
class UnknownCategoryError(ConformanceError):
    category: str

    def __str__(self) -> str:
        return f"unknown category {self.category!r}"


@dataclass(eq=True)
class UnknownTagError(ConformanceError):
    tag: str

    def __str__(self) -> str:
        return f"unknown tag {self.tag!r}"


@dataclass(eq=True)
class SelectionNumberFormatError(ConformanceError):
    cause: ValueError

    def __str__(self) -> str:
        return "selection must contain test numbers"


@dataclass(eq=True)
class SelectionNumberOutOfRangeError(ConformanceError):
    values: tuple[int, ...]
    available: int

    def __str__(self) -> str:
        return "selection contains an unknown test number"


@dataclass(eq=True)
class DuplicateSelectionNumberError(ConformanceError):
    values: tuple[int, ...]

    def __str__(self) -> str:
        return "selection contains a duplicate test number"


class JsonFrontend:
    def __init__(self, stream: TextIO) -> None:
        self._stream = stream
        self._lock = threading.Lock()
        self._tasks = JsonTaskView(self._write)

    def emit(self, event: Event) -> None:
        value = msgspec.to_builtins(event, enc_hook=encode_special)
        value["event"] = type(event).__name__
        self._write(value)

    def observe(self, root: TaskRun) -> None:
        """Attach JSON task reporting to a new root."""

        self._tasks.observe(root)

    def announce(self, message: str) -> None:
        """Accept an urgent notice; JSON consumers see the typed events."""

    def _write(self, value: Any) -> None:
        value = msgspec.to_builtins(value, enc_hook=encode_special)
        with self._lock:
            print(json.dumps(value, sort_keys=True), file=self._stream, flush=True)


class RichFrontend:
    def __init__(self, console: Console) -> None:
        self._console = console
        self._tasks = RichTaskView(console)
        self._lock = threading.RLock()

    def observe(self, root: TaskRun) -> None:
        """Attach Rich task rendering to a new root."""

        self._tasks.observe(root)

    def announce(self, message: str) -> None:
        """Pin an urgent notice above the live task tree."""

        self._tasks.announce(message)

    def emit(self, event: Event) -> None:
        with self._lock:
            self._emit(event)

    def _emit(self, event: Event) -> None:
        match event:
            case TestFinished():
                self._finish_test(event)
            case SuiteFinished():
                self._finish_suite(event)
            case SuiteInterrupted():
                self._console.print(
                    "\n[yellow]Prompt conformance interrupted.[/yellow]"
                )
                self._console.print(f"Partial results: {event.output}")
            case ImprovementFinished():
                self._finish_improvement(event)
            case ImprovementAborted():
                pass

    def _finish_suite(self, event: SuiteFinished) -> None:
        successful = event.failed == 0 and event.invalid == 0 and event.stale == 0
        status = "[green]passed[/green]" if successful else "[red]failed[/red]"
        self._console.print(
            f"\nPrompt conformance {status}: "
            f"{event.passed} passed, {event.failed} failed, "
            f"{event.invalid} invalid, {event.stale} stale"
        )
        self._console.print(f"Results: {event.output}")
        self._console.print(f"Run metadata: {event.run_metadata}")

    def _finish_improvement(self, event: ImprovementFinished) -> None:
        status = (
            "[green]accepted[/green]"
            if event.reserved_checks_accepted
            else "[red]rejected[/red]"
        )
        self._console.print(
            f"\nPrompt improvement {status}: "
            f"{event.accepted_proposals} accepted from "
            f"{event.attempted_proposals} attempted proposals"
        )
        if event.winner_patch is not None:
            self._console.print(f"Winning patch: {event.winner_patch}")
        self._console.print(f"Results: {event.output}")

    def _finish_test(self, event: TestFinished) -> None:
        if event.result is None:
            for failure in event.failures:
                self._console.print(f"[red]FAIL[/red] {event.fixture_name}: {failure}")
            return

        presentation = result_presentation(event)
        candidate_work = Group(
            Markdown(presentation.response),
            Rule("Git changelog"),
            Syntax(
                presentation.changelog,
                "text",
                word_wrap=True,
            ),
            Rule("Changed files"),
            Text("\n".join(presentation.changed_files) or "No changed files."),
        )
        if event.status is TestStatus.PASSED:
            self._console.print(
                Panel(
                    candidate_work,
                    title=f"{event.fixture_name}: candidate work",
                    border_style="green",
                )
            )
        else:
            comparison = Table.grid(expand=True, padding=(0, 1))
            comparison.add_column(ratio=1)
            comparison.add_column(ratio=1)
            comparison.add_row(
                Panel(candidate_work, title="Candidate work", border_style="red"),
                Panel(
                    Group(
                        Markdown(presentation.recommendation or ""),
                        Rule("Counterfactual work"),
                        Markdown(presentation.counterfactual or ""),
                        Rule("Corrected handoff"),
                        Markdown(presentation.corrected_response or ""),
                    ),
                    title="Judge counterfactual",
                    border_style="yellow",
                ),
            )
            self._console.print(
                Panel(comparison, title=event.fixture_name, border_style="red")
            )
            assessment = Table(title="Failed criteria", show_header=True)
            assessment.add_column("Criterion")
            assessment.add_column("Assessment")
            for criterion in presentation.failed_criteria:
                assessment.add_row(criterion.identifier, criterion.assessment)
            self._console.print(assessment)
        if presentation.checks:
            checks = Table(title="Deterministic checks")
            checks.add_column("Check")
            checks.add_column("Result")
            for check in presentation.checks:
                checks.add_row(check.name, check_result(check))
            self._console.print(checks)


def check_result(check: "CheckPresentation") -> str:
    """Describe one check, marking a gate which only passed when retried."""

    if not check.passed:
        return "[red]fail[/red]"
    if check.flaky:
        return "[yellow]flaky[/yellow]"
    return "[green]pass[/green]"


def choose_fixtures(fixtures: tuple[Fixture, ...], console: Console) -> tuple[str, ...]:
    table = catalogue_table(fixtures)
    console.print(table)
    console.print(
        "Select [bold]all[/bold], comma-separated numbers, "
        "[bold]category:NAME[/bold], or [bold]tag:NAME[/bold]."
    )
    while True:
        answer = Prompt.ask("Tests", default="all", console=console).strip()
        try:
            return parse_interactive_selection(answer, fixtures)
        except ConformanceError as error:
            console.print(f"[red]{error}[/red]")


@dataclass(frozen=True)
class CatalogueEntry:
    """The user-facing summary of one selectable fixture."""

    number: int
    name: str
    kind: str
    use: str
    category: str
    description: str
    tags: tuple[str, ...]


@dataclass(frozen=True)
class CriterionPresentation:
    """A failed criterion and the judge's explanation."""

    identifier: str
    assessment: str


@dataclass(frozen=True)
class CheckPresentation:
    """A deterministic check result shown with the candidate's work."""

    name: str
    passed: bool
    flaky: bool = False


@dataclass(frozen=True)
class ResultPresentation:
    """The model work and conditional corrective detail shown for one result."""

    response: str
    changelog: str
    changed_files: tuple[str, ...]
    recommendation: str | None
    counterfactual: str | None
    corrected_response: str | None
    failed_criteria: tuple[CriterionPresentation, ...]
    checks: tuple[CheckPresentation, ...]


def result_presentation(event: TestFinished) -> ResultPresentation:
    """Build complete presentation data without coupling it to Rich rendering."""

    if event.result is None:
        raise ResultPresentationUnavailableError(event.fixture_name)

    result = event.result
    return ResultPresentation(
        response=result.candidate.response,
        changelog=result.evidence.commits.read_text().strip() or "No commits recorded.",
        changed_files=result.evidence.changed_files,
        recommendation=(
            None
            if event.status is TestStatus.PASSED
            else result.judgement.recommendation
        ),
        counterfactual=(
            None
            if event.status is TestStatus.PASSED
            else result.judgement.counterfactual
        ),
        corrected_response=(
            None
            if event.status is TestStatus.PASSED
            else result.judgement.corrected_response
        ),
        failed_criteria=tuple(
            CriterionPresentation(criterion.identifier, criterion.reason)
            for criterion in result.judgement.criteria
            if not criterion.passed
        ),
        checks=tuple(
            CheckPresentation(check.name, check.passed, check.flaky)
            for check in result.verification
        ),
    )


def catalogue_entries(fixtures: tuple[Fixture, ...]) -> tuple[CatalogueEntry, ...]:
    """Build stable catalogue data independently of terminal rendering."""

    return tuple(
        CatalogueEntry(
            number=index,
            name=fixture.name,
            kind=fixture.kind.value,
            use=fixture.use.value,
            category=fixture.category,
            description=fixture.description,
            tags=fixture.tags,
        )
        for index, fixture in enumerate(fixtures, start=1)
    )


def catalogue_table(fixtures: tuple[Fixture, ...]) -> Table:
    table = Table(title="Prompt conformance tests", expand=True)
    table.add_column("#", justify="right", style="cyan")
    table.add_column("Test", style="bold")
    table.add_column("Kind")
    table.add_column("Use")
    table.add_column("Category")
    table.add_column("Description", ratio=3, overflow="fold")
    for entry in catalogue_entries(fixtures):
        description = Text(entry.description)
        description.append(f"\ntags: {', '.join(entry.tags)}", style="dim")
        table.add_row(
            str(entry.number),
            entry.name,
            entry.kind,
            entry.use,
            entry.category,
            description,
        )

    return table


def parse_interactive_selection(
    answer: str, fixtures: tuple[Fixture, ...]
) -> tuple[str, ...]:
    if answer == "all":
        return tuple(fixture.name for fixture in fixtures)

    if answer.startswith("category:"):
        category = answer.removeprefix("category:")
        names = tuple(
            fixture.name for fixture in fixtures if fixture.category == category
        )
        if names:
            return names
        raise UnknownCategoryError(category)

    if answer.startswith("tag:"):
        tag = answer.removeprefix("tag:")
        names = tuple(fixture.name for fixture in fixtures if tag in fixture.tags)
        if names:
            return names
        raise UnknownTagError(tag)

    try:
        indexes = tuple(int(value.strip()) for value in answer.split(","))
    except ValueError as error:
        raise SelectionNumberFormatError(error) from error

    if not indexes or any(index < 1 or index > len(fixtures) for index in indexes):
        raise SelectionNumberOutOfRangeError(indexes, len(fixtures))
    if len(indexes) != len(set(indexes)):
        raise DuplicateSelectionNumberError(indexes)

    return tuple(fixtures[index - 1].name for index in indexes)


def encode_special(value: Any) -> str:
    """Represent filesystem paths at the structured JSON frontend boundary."""

    match value:
        case Path():
            return str(value)
        case Enum():
            return value.value
        case _:
            raise NotImplementedError
