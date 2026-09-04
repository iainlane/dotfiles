"""Scoped, observable task runs for hierarchical progress."""

import asyncio
import time
from collections.abc import Callable, Iterator
from concurrent.futures import Executor, Future
from contextlib import contextmanager
from contextvars import ContextVar, copy_context
from dataclasses import dataclass
from enum import StrEnum
from threading import RLock
from typing import Protocol

from psygnal import Signal, SignalGroup

from .errors import TaskInvariantError
from .task_children import (
    FixedTaskChildren,
    TaskChildAllocations,
    TaskChildren,
    TaskChildrenSnapshot,
)


@dataclass(eq=True)
class MissingTaskContextError(TaskInvariantError):
    task: str

    def __str__(self) -> str:
        return f"progress task {self.task!r} has no active parent"


@dataclass(eq=True)
class NestedRootTaskError(TaskInvariantError):
    task: str
    parent: tuple[str, ...]

    def __str__(self) -> str:
        return f"root progress task {self.task!r} was started beneath {self.parent!r}"


@dataclass(eq=True)
class DuplicateTaskChildError(TaskInvariantError):
    parent: tuple[str, ...]
    child: str

    def __str__(self) -> str:
        return f"progress task {self.parent!r} already has child {self.child!r}"


@dataclass(eq=True)
class DuplicateTaskChildOrderError(TaskInvariantError):
    parent: tuple[str, ...]
    order: int
    existing: str
    child: str

    def __str__(self) -> str:
        return (
            f"progress task {self.parent!r} gives children {self.existing!r} "
            f"and {self.child!r} order {self.order}"
        )


@dataclass(eq=True)
class FinishedTaskMutationError(TaskInvariantError):
    task: tuple[str, ...]

    def __str__(self) -> str:
        return f"finished progress task {self.task!r} cannot be changed"


@dataclass(eq=True)
class RunningTaskChildrenError(TaskInvariantError):
    task: tuple[str, ...]
    children: tuple[tuple[str, ...], ...]

    def __str__(self) -> str:
        return f"progress task {self.task!r} has running children {self.children!r}"


@dataclass(eq=True)
class IncompleteTaskChildrenError(TaskInvariantError):
    task: tuple[str, ...]
    children: tuple[str, ...]

    def __str__(self) -> str:
        return f"passing progress task {self.task!r} has incomplete children {self.children!r}"


@dataclass(eq=True)
class DuplicateTaskActivityError(TaskInvariantError):
    task: tuple[str, ...]
    activity: str

    def __str__(self) -> str:
        return f"progress task {self.task!r} already has activity {self.activity!r}"


@dataclass(eq=True)
class UnknownTaskActivityError(TaskInvariantError):
    task: tuple[str, ...]
    activity: str

    def __str__(self) -> str:
        return f"progress task {self.task!r} has no activity {self.activity!r}"


class TaskKind(StrEnum):
    """The semantic role of one unit in a conformance run."""

    IMPROVEMENT = "improvement"
    ITERATION = "iteration"
    EVALUATION = "evaluation"
    SAMPLE = "sample"
    SUITE = "suite"
    FIXTURE = "fixture"
    PHASE = "phase"


class TaskOutcome(StrEnum):
    """The terminal outcome of a progress task."""

    COMPLETED = "completed"
    PASSED = "passed"
    FAILED = "failed"
    INVALID = "invalid"
    CANCELLED = "cancelled"
    SKIPPED = "skipped"


class TaskChangeKind(StrEnum):
    """The lifecycle transition represented by a task notification."""

    ADDED = "added"
    UPDATED = "updated"
    FINISHED = "finished"


@dataclass(frozen=True)
class TaskActivity:
    """The current observable operation within a longer-running task."""

    identifier: str
    description: str
    sequence: int
    started_at: float
    observed_at: float
    elapsed_seconds: int
    heartbeat: bool


@dataclass(frozen=True)
class TaskSnapshot:
    """An immutable recursive view of one task and its descendants."""

    path: tuple[str, ...]
    kind: TaskKind
    description: str
    detail: str
    completed: int
    total: int | None
    outcome: TaskOutcome | None
    revision: int
    started_at: float
    finished_at: float | None
    children: tuple["TaskSnapshot", ...]
    child_progress: TaskChildrenSnapshot
    activity: TaskActivity | None = None
    activities: int = 0
    active_activities: int = 0


@dataclass(frozen=True)
class TaskChange:
    """A typed notification emitted by a task and bubbled to its root."""

    kind: TaskChangeKind
    task: TaskSnapshot


class TaskSignals(SignalGroup):
    """Signals emitted by one task run."""

    changed = Signal(TaskChange)


class TaskObserver(Protocol):
    """Attach a presentation adapter to a newly created root task."""

    def observe(self, root: "TaskRun") -> None: ...


class TaskRun:
    """Own the live state, signals, and relationships of one scoped task."""

    def __init__(
        self,
        name: str,
        kind: TaskKind,
        description: str,
        children: TaskChildren,
        order: int,
        clock: Callable[[], float],
        parent: "TaskRun | None",
    ) -> None:
        self.name = name
        self.kind = kind
        self.description = description
        self.order = order
        self.parent = parent
        self.signals = TaskSignals()
        self._clock = clock
        self._detail = "Waiting"
        self._child_progress = TaskChildAllocations(children)
        self._outcome: TaskOutcome | None = None
        self._revision = 0
        self._started_at = clock()
        self._finished_at: float | None = None
        self._active_activities: dict[str, TaskActivity] = {}
        self._activity_sequence = 0
        self._children: list[TaskRun] = []
        self._lock = parent._lock if parent is not None else RLock()

        if parent is not None:
            parent._register(self)

    @property
    def path(self) -> tuple[str, ...]:
        """Return the stable path formed by this task's ancestors."""

        if self.parent is None:
            return (self.name,)

        return (*self.parent.path, self.name)

    @property
    def outcome(self) -> TaskOutcome | None:
        """Return the terminal outcome, if this task has finished."""

        with self._lock:
            return self._outcome

    @property
    def children(self) -> tuple["TaskRun", ...]:
        """Return child tasks in their deterministic presentation order."""

        with self._lock:
            return tuple(sorted(self._children, key=lambda child: child.order))

    def complete_child(self, name: str, detail: str) -> None:
        """Complete one declared child region implemented directly by this task."""

        with self._lock:
            self._ensure_running()
            self._child_progress.complete(name, direct=True)
            self._detail = detail
            self._revision += 1
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def seal_children(self, detail: str) -> None:
        """Declare that an open task will create no additional children."""

        with self._lock:
            self._ensure_running()
            self._child_progress.seal()
            self._detail = detail
            self._revision += 1
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def set_description(self, description: str) -> None:
        """Replace the user-facing description as the work becomes concrete."""

        with self._lock:
            self._ensure_running()
            self.description = description
            self._revision += 1
            change = TaskChange(TaskChangeKind.UPDATED, self._snapshot())
            self._publish(change)

    def set_detail(self, detail: str) -> None:
        """Report what this task is doing without inferring from its children."""

        with self._lock:
            self._ensure_running()
            self._detail = detail
            self._revision += 1
            change = TaskChange(TaskChangeKind.UPDATED, self._snapshot())
            self._publish(change)

    def start_activity(self, identifier: str, description: str) -> None:
        """Record a new observable operation without claiming task completion."""

        with self._lock:
            self._ensure_running()
            if identifier in self._active_activities:
                raise DuplicateTaskActivityError(self.path, identifier)
            observed_at = self._clock()
            self._activity_sequence += 1
            self._active_activities[identifier] = TaskActivity(
                identifier=identifier,
                description=description,
                sequence=self._activity_sequence,
                started_at=observed_at,
                observed_at=observed_at,
                elapsed_seconds=0,
                heartbeat=False,
            )
            self._revision += 1
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def heartbeat_activity(self, identifier: str, elapsed_seconds: int) -> None:
        """Record liveness for the current operation without treating it as progress."""

        with self._lock:
            self._ensure_running()
            try:
                activity = self._active_activities[identifier]
            except KeyError as error:
                raise UnknownTaskActivityError(self.path, identifier) from error
            self._active_activities[identifier] = TaskActivity(
                identifier=identifier,
                description=activity.description,
                sequence=activity.sequence,
                started_at=activity.started_at,
                observed_at=self._clock(),
                elapsed_seconds=elapsed_seconds,
                heartbeat=True,
            )
            self._revision += 1
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def finish_activity(self, identifier: str, detail: str) -> None:
        """Clear the current operation after an observable completion event."""

        with self._lock:
            self._ensure_running()
            try:
                del self._active_activities[identifier]
            except KeyError as error:
                raise UnknownTaskActivityError(self.path, identifier) from error
            self._detail = detail
            self._revision += 1
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def finish(self, outcome: TaskOutcome, detail: str) -> None:
        """Finish this task after every child reaches a terminal outcome.

        A cancellation is the exception: it finishes running children as
        cancelled instead of failing, because an interrupt can reach a parent
        while the threads driving its children are still being stopped.
        """

        with self._lock:
            self._ensure_running()
            if outcome is TaskOutcome.CANCELLED:
                for child in self.children:
                    if child.outcome is None:
                        child.finish(TaskOutcome.CANCELLED, "Cancelled")
            running = tuple(
                child.path for child in self._children if child.outcome is None
            )
            if running:
                raise RunningTaskChildrenError(self.path, running)
            if not self._child_progress.sealed:
                self._child_progress.seal()
            progress = self._child_progress.snapshot()
            incomplete = tuple(
                child.name for child in progress.children if not child.completed
            )
            if outcome in (TaskOutcome.COMPLETED, TaskOutcome.PASSED) and incomplete:
                raise IncompleteTaskChildrenError(self.path, incomplete)
            self._outcome = outcome
            self._active_activities.clear()
            self._detail = detail
            self._revision += 1
            self._finished_at = self._clock()
            if self.parent is not None:
                self.parent._child_finished(self.name)
            change = TaskChange(TaskChangeKind.FINISHED, self._snapshot())
            self._publish(change)
            if self.parent is not None:
                self.parent._publish_progress()

    def snapshot(self) -> TaskSnapshot:
        """Capture this task tree as immutable values."""

        with self._lock:
            return self._snapshot()

    def _snapshot(self) -> TaskSnapshot:
        children = tuple(
            child.snapshot()
            for child in sorted(self._children, key=lambda child: child.order)
        )
        progress = self._child_progress.snapshot()
        return TaskSnapshot(
            path=self.path,
            kind=self.kind,
            description=self.description,
            detail=self._detail,
            completed=progress.completed,
            total=progress.total,
            outcome=self._outcome,
            revision=self._revision,
            started_at=self._started_at,
            finished_at=self._finished_at,
            children=children,
            child_progress=progress,
            activity=max(
                self._active_activities.values(),
                key=lambda activity: (activity.observed_at, activity.sequence),
                default=None,
            ),
            activities=self._activity_sequence,
            active_activities=len(self._active_activities),
        )

    def _register(self, child: "TaskRun") -> None:
        with self._lock:
            self._ensure_running()
            if any(existing.name == child.name for existing in self._children):
                raise DuplicateTaskChildError(self.path, child.name)
            for existing in self._children:
                if existing.order == child.order:
                    raise DuplicateTaskChildOrderError(
                        self.path,
                        child.order,
                        existing.name,
                        child.name,
                    )
            self._child_progress.register(child.name)
            self._children.append(child)
            change = TaskChange(TaskChangeKind.ADDED, child.snapshot())
            self._publish(change)

    def _child_finished(self, name: str) -> None:
        self._child_progress.complete(name)
        self._revision += 1

    def _publish_progress(self) -> None:
        with self._lock:
            if self._outcome is not None:
                return
            self._publish(TaskChange(TaskChangeKind.UPDATED, self._snapshot()))

    def _publish(self, change: TaskChange) -> None:
        self.signals.changed.emit(change)
        if self.parent is not None:
            self.parent._publish(change)

    def _ensure_running(self) -> None:
        if self._outcome is not None:
            raise FinishedTaskMutationError(self.path)


_current_task: ContextVar[TaskRun | None] = ContextVar(
    "prompt_conformance_task", default=None
)


class TaskScopes:
    """Create lexical task scopes and attach observers to their roots."""

    def __init__(
        self,
        observer: TaskObserver,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._observer = observer
        self._clock = clock

    @contextmanager
    def root(
        self,
        name: str,
        kind: TaskKind,
        description: str,
        children: TaskChildren | None = None,
    ) -> Iterator[TaskRun]:
        """Run a root task within the current execution context."""

        parent = _current_task.get()
        if parent is not None:
            raise NestedRootTaskError(name, parent.path)
        task = TaskRun(
            name,
            kind,
            description,
            children or FixedTaskChildren(),
            0,
            self._clock,
            None,
        )
        self._observer.observe(task)
        with self._activate(task):
            yield task

    @contextmanager
    def task(
        self,
        name: str,
        kind: TaskKind,
        description: str,
        children: TaskChildren,
        order: int,
    ) -> Iterator[TaskRun]:
        """Run a child task beneath the current lexical task."""

        parent = _current_task.get()
        if parent is None:
            raise MissingTaskContextError(name)
        task = TaskRun(name, kind, description, children, order, self._clock, parent)
        with self._activate(task):
            yield task

    @contextmanager
    def _activate(self, task: TaskRun) -> Iterator[None]:
        token = _current_task.set(task)
        try:
            yield
        except KeyboardInterrupt:
            if task.outcome is None:
                task.finish(TaskOutcome.CANCELLED, "Interrupted")
            raise
        except asyncio.CancelledError:
            if task.outcome is None:
                task.finish(TaskOutcome.CANCELLED, "Cancelled")
            raise
        except BaseException:
            if task.outcome is None:
                task.finish(TaskOutcome.FAILED, "Failed")
            raise
        else:
            if task.outcome is None:
                try:
                    task.finish(TaskOutcome.COMPLETED, "Completed")
                except BaseException:
                    if task.outcome is None:
                        task.finish(TaskOutcome.FAILED, "Failed")
                    raise
        finally:
            _current_task.reset(token)


def current_task() -> TaskRun | None:
    """Return the task active in this execution context."""

    return _current_task.get()


def submit_in_context[**Parameters, Result](
    executor: Executor,
    function: Callable[Parameters, Result],
    *args: Parameters.args,
    **kwargs: Parameters.kwargs,
) -> Future[Result]:
    """Submit work with a fresh copy of the caller's task context."""

    context = copy_context()
    return executor.submit(context.run, function, *args, **kwargs)
