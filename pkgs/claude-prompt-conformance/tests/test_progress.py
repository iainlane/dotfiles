import asyncio
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest

from claude_prompt_conformance.progress import (
    DuplicateTaskActivityError,
    DuplicateTaskChildError,
    DuplicateTaskChildOrderError,
    FinishedTaskMutationError,
    IncompleteTaskChildrenError,
    MissingTaskContextError,
    NestedRootTaskError,
    RunningTaskChildrenError,
    TaskActivity,
    TaskChange,
    TaskChangeKind,
    TaskKind,
    TaskOutcome,
    TaskRun,
    TaskScopes,
    TaskSnapshot,
    UnknownTaskActivityError,
    submit_in_context,
)
from claude_prompt_conformance.task_children import (
    BoundedTaskChildren,
    BoundedTaskChildrenOverflowError,
    ChildAllocation,
    DuplicateTaskChildAllocationError,
    FixedTaskChildren,
    InvalidTaskChildWeightError,
    NegativeBoundedTaskChildrenMaximumError,
    TaskChildAlreadyCompletedError,
    TaskChildrenKind,
    TaskChildrenSnapshot,
    TaskChildSnapshot,
    UnboundedTaskChildren,
    UndeclaredTaskChildError,
)

from .helpers import RecordingRoots


def empty_children(*, sealed: bool = True) -> TaskChildrenSnapshot:
    return TaskChildrenSnapshot(
        kind=(TaskChildrenKind.FIXED if sealed else TaskChildrenKind.UNBOUNDED),
        sealed=sealed,
        maximum=None,
        children=(),
    )


def test_scoped_tasks_retain_complete_parent_child_state() -> None:
    roots = RecordingRoots()
    times = iter((1.0, 2.0, 3.0, 4.0))
    scopes = TaskScopes(roots, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("fixture"),
    ) as root:
        with scopes.task(
            "fixture",
            TaskKind.FIXTURE,
            "Fixture",
            FixedTaskChildren.equal("prepare", "judge"),
            0,
        ) as child:
            child.complete_child("prepare", "Prepared")
            child.finish(TaskOutcome.FAILED, "Judge rejected the work")
        root.finish(TaskOutcome.FAILED, "One fixture failed")

    assert tuple(task.snapshot() for task in roots.roots) == (
        TaskSnapshot(
            path=("run",),
            kind=TaskKind.SUITE,
            description="Conformance",
            detail="One fixture failed",
            completed=1,
            total=1,
            outcome=TaskOutcome.FAILED,
            revision=2,
            started_at=1.0,
            finished_at=4.0,
            children=(
                TaskSnapshot(
                    path=("run", "fixture"),
                    kind=TaskKind.FIXTURE,
                    description="Fixture",
                    detail="Judge rejected the work",
                    completed=1,
                    total=2,
                    outcome=TaskOutcome.FAILED,
                    revision=2,
                    started_at=2.0,
                    finished_at=3.0,
                    children=(),
                    child_progress=TaskChildrenSnapshot(
                        kind=TaskChildrenKind.FIXED,
                        sealed=True,
                        maximum=None,
                        children=(
                            TaskChildSnapshot("prepare", 1.0, False, True),
                            TaskChildSnapshot("judge", 1.0, False, False),
                        ),
                    ),
                ),
            ),
            child_progress=TaskChildrenSnapshot(
                kind=TaskChildrenKind.FIXED,
                sealed=True,
                maximum=None,
                children=(TaskChildSnapshot("fixture", 1.0, True, True),),
            ),
        ),
    )


def test_task_tracks_parallel_activities_by_identity() -> None:
    roots = RecordingRoots()
    times = iter((1.0, 2.0, 3.0, 4.0, 5.0))
    scopes = TaskScopes(roots, lambda: next(times))

    with scopes.root("run", TaskKind.SUITE, "Conformance") as task:
        task.start_activity("tool-a", "Bash: Run checks")
        task.start_activity("tool-b", "Agent: Review results")
        task.heartbeat_activity("tool-a", 10)
        task.finish_activity("tool-a", "Checks finished")
        running = task.snapshot()

    assert running == TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Conformance",
        detail="Checks finished",
        completed=0,
        total=0,
        outcome=None,
        revision=4,
        started_at=1.0,
        finished_at=None,
        children=(),
        child_progress=empty_children(),
        activity=TaskActivity(
            identifier="tool-b",
            description="Agent: Review results",
            sequence=2,
            started_at=3.0,
            observed_at=3.0,
            elapsed_seconds=0,
            heartbeat=False,
        ),
        activities=2,
        active_activities=1,
    )


def test_task_owner_reports_detail_independently_of_its_children() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("fixture"),
    ) as root:
        root.set_detail("Running fixtures")
        with scopes.task(
            "fixture", TaskKind.FIXTURE, "Fixture", FixedTaskChildren(), 0
        ) as fixture:
            fixture.set_detail("Calibrating the judge")
            running = root.snapshot()

    assert (
        running.detail,
        tuple(child.detail for child in running.children),
    ) == (
        "Running fixtures",
        ("Calibrating the judge",),
    )


@pytest.mark.parametrize(
    ("operation", "expected"),
    (
        (
            lambda task: task.start_activity("tool", "Duplicate"),
            DuplicateTaskActivityError(("run",), "tool"),
        ),
        (
            lambda task: task.heartbeat_activity("missing", 1),
            UnknownTaskActivityError(("run",), "missing"),
        ),
        (
            lambda task: task.finish_activity("missing", "Finished"),
            UnknownTaskActivityError(("run",), "missing"),
        ),
    ),
)
def test_task_rejects_invalid_activity_transitions(
    operation: Callable[[TaskRun], None],
    expected: DuplicateTaskActivityError | UnknownTaskActivityError,
) -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root("run", TaskKind.SUITE, "Conformance") as task:
        task.start_activity("tool", "Running")
        with pytest.raises(type(expected)) as raised:
            operation(task)

    assert raised.value == expected


def test_thread_submission_preserves_the_current_task_context() -> None:
    roots = RecordingRoots()
    times = iter((1.0, 2.0, 3.0, 4.0))
    scopes = TaskScopes(roots, lambda: next(times))

    def run_child() -> None:
        with scopes.task("worker", TaskKind.FIXTURE, "Worker", FixedTaskChildren(), 0):
            pass

    with (
        scopes.root("run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()),
        ThreadPoolExecutor(max_workers=1) as executor,
    ):
        submit_in_context(executor, run_child).result()

    assert tuple(task.snapshot() for task in roots.roots) == (
        TaskSnapshot(
            path=("run",),
            kind=TaskKind.SUITE,
            description="Conformance",
            detail="Completed",
            completed=1,
            total=1,
            outcome=TaskOutcome.COMPLETED,
            revision=2,
            started_at=1.0,
            finished_at=4.0,
            children=(
                TaskSnapshot(
                    path=("run", "worker"),
                    kind=TaskKind.FIXTURE,
                    description="Worker",
                    detail="Completed",
                    completed=0,
                    total=0,
                    outcome=TaskOutcome.COMPLETED,
                    revision=1,
                    started_at=2.0,
                    finished_at=3.0,
                    children=(),
                    child_progress=empty_children(),
                ),
            ),
            child_progress=TaskChildrenSnapshot(
                kind=TaskChildrenKind.UNBOUNDED,
                sealed=True,
                maximum=None,
                children=(TaskChildSnapshot("worker", 1.0, True, True),),
            ),
        ),
    )


def test_child_terminal_signal_precedes_parent_progress_signal() -> None:
    times = iter((1.0, 2.0, 3.0, 4.0))
    root = TaskRun(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("worker"),
        0,
        lambda: next(times),
        None,
    )
    child = TaskRun(
        "worker",
        TaskKind.FIXTURE,
        "Worker",
        FixedTaskChildren(),
        0,
        lambda: next(times),
        root,
    )
    child_signal_started = Event()
    release_child_signal = Event()
    parent_finish_started = Event()
    changes: list[tuple[TaskChangeKind, tuple[str, ...]]] = []

    def record(change: TaskChange) -> None:
        changes.append((change.kind, change.task.path))
        if change.task.path == child.path:
            child_signal_started.set()
            release_child_signal.wait()

    def finish_parent() -> None:
        parent_finish_started.set()
        root.finish(TaskOutcome.PASSED, "Complete")

    root.signals.changed.connect(record)
    with ThreadPoolExecutor(max_workers=2) as executor:
        child_future = executor.submit(child.finish, TaskOutcome.PASSED, "Complete")
        child_signal_started.wait()
        parent_future = executor.submit(finish_parent)
        parent_finish_started.wait()
        try:
            assert not parent_future.done()
        finally:
            release_child_signal.set()
        child_future.result()
        parent_future.result()

    assert changes == [
        (TaskChangeKind.FINISHED, ("run", "worker")),
        (TaskChangeKind.UPDATED, ("run",)),
        (TaskChangeKind.FINISHED, ("run",)),
    ]


def test_reentrant_parent_finish_does_not_emit_stale_progress() -> None:
    root = TaskRun(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("worker"),
        0,
        lambda: 1.0,
        None,
    )
    child = TaskRun(
        "worker",
        TaskKind.FIXTURE,
        "Worker",
        FixedTaskChildren(),
        0,
        lambda: 1.0,
        root,
    )
    changes: list[TaskChange] = []

    def finish_parent(change: TaskChange) -> None:
        changes.append(change)
        if change.task.path == child.path:
            root.finish(TaskOutcome.PASSED, "Complete")

    root.signals.changed.connect(finish_parent)
    child.finish(TaskOutcome.PASSED, "Complete")

    assert tuple(
        (change.kind, change.task.path, change.task.revision, change.task.outcome)
        for change in changes
    ) == (
        (
            TaskChangeKind.FINISHED,
            ("run", "worker"),
            1,
            TaskOutcome.PASSED,
        ),
        (TaskChangeKind.FINISHED, ("run",), 2, TaskOutcome.PASSED),
    )


def test_bare_thread_submission_has_no_task_context() -> None:
    scopes = TaskScopes(RecordingRoots())

    def run_child() -> None:
        with scopes.task("worker", TaskKind.FIXTURE, "Worker", FixedTaskChildren(), 0):
            pass

    with (
        scopes.root("run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()),
        ThreadPoolExecutor(max_workers=1) as executor,
    ):
        future = executor.submit(run_child)

        with pytest.raises(MissingTaskContextError) as raised:
            future.result()

    assert raised.value == MissingTaskContextError("worker")


@pytest.mark.parametrize(
    ("construct", "expected"),
    (
        (
            lambda: ChildAllocation("child", 0),
            InvalidTaskChildWeightError("child", 0),
        ),
        (
            lambda: ChildAllocation("child", float("inf")),
            InvalidTaskChildWeightError("child", float("inf")),
        ),
        (
            lambda: FixedTaskChildren.equal("child", "child"),
            DuplicateTaskChildAllocationError("child"),
        ),
        (
            lambda: BoundedTaskChildren(-1),
            NegativeBoundedTaskChildrenMaximumError(-1),
        ),
    ),
)
def test_child_specifications_reject_invalid_construction(
    construct: Callable[[], object],
    expected: InvalidTaskChildWeightError
    | DuplicateTaskChildAllocationError
    | NegativeBoundedTaskChildrenMaximumError,
) -> None:
    with pytest.raises(type(expected)) as raised:
        construct()

    assert raised.value == expected


def test_bounded_children_use_the_pessimistic_total_until_sealed() -> None:
    roots = RecordingRoots()
    scopes = TaskScopes(roots)

    with scopes.root(
        "run", TaskKind.SUITE, "Conformance", BoundedTaskChildren(3)
    ) as root:
        with scopes.task("first", TaskKind.FIXTURE, "First", FixedTaskChildren(), 0):
            pass
        before_sealing = root.snapshot()
        root.seal_children("All work discovered")
        after_sealing = root.snapshot()

    assert (before_sealing.child_progress, after_sealing.child_progress) == (
        TaskChildrenSnapshot(
            kind=TaskChildrenKind.BOUNDED,
            sealed=False,
            maximum=3,
            children=(TaskChildSnapshot("first", 1.0, True, True),),
        ),
        TaskChildrenSnapshot(
            kind=TaskChildrenKind.BOUNDED,
            sealed=True,
            maximum=3,
            children=(TaskChildSnapshot("first", 1.0, True, True),),
        ),
    )
    assert (
        (before_sealing.completed, before_sealing.total),
        (after_sealing.completed, after_sealing.total),
    ) == ((1, 3), (1, 1))


def test_bounded_children_can_discover_direct_work_regions() -> None:
    roots = RecordingRoots()
    scopes = TaskScopes(roots)

    with scopes.root(
        "run", TaskKind.SUITE, "Conformance", BoundedTaskChildren(2)
    ) as root:
        root.complete_child("discovered", "Discovered work complete")
        running = root.snapshot()
        root.seal_children("All work discovered")

    assert running.child_progress == TaskChildrenSnapshot(
        kind=TaskChildrenKind.BOUNDED,
        sealed=False,
        maximum=2,
        children=(TaskChildSnapshot("discovered", 1.0, False, True),),
    )
    assert (running.completed, running.total) == (1, 2)


def test_unbounded_children_are_indeterminate_until_sealed() -> None:
    roots = RecordingRoots()
    scopes = TaskScopes(roots)

    with scopes.root(
        "run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()
    ) as root:
        with scopes.task("first", TaskKind.FIXTURE, "First", FixedTaskChildren(), 0):
            pass
        before_sealing = root.snapshot()
        root.seal_children("All work discovered")
        after_sealing = root.snapshot()

    assert (before_sealing.child_progress, after_sealing.child_progress) == (
        TaskChildrenSnapshot(
            kind=TaskChildrenKind.UNBOUNDED,
            sealed=False,
            maximum=None,
            children=(TaskChildSnapshot("first", 1.0, True, True),),
        ),
        TaskChildrenSnapshot(
            kind=TaskChildrenKind.UNBOUNDED,
            sealed=True,
            maximum=None,
            children=(TaskChildSnapshot("first", 1.0, True, True),),
        ),
    )
    assert (
        (before_sealing.completed, before_sealing.total),
        (after_sealing.completed, after_sealing.total),
    ) == ((1, None), (1, 1))


def test_bounded_children_reject_more_than_the_declared_maximum() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root("run", TaskKind.SUITE, "Conformance", BoundedTaskChildren(1)):
        with scopes.task("first", TaskKind.FIXTURE, "First", FixedTaskChildren(), 0):
            pass

        with (
            pytest.raises(BoundedTaskChildrenOverflowError) as raised,
            scopes.task("second", TaskKind.FIXTURE, "Second", FixedTaskChildren(), 1),
        ):
            pass

    assert raised.value == BoundedTaskChildrenOverflowError(1, 2)


def test_fixed_children_reject_undeclared_tasks() -> None:
    scopes = TaskScopes(RecordingRoots())

    with (
        scopes.root(
            "run",
            TaskKind.SUITE,
            "Conformance",
            FixedTaskChildren(),
        ),
        pytest.raises(UndeclaredTaskChildError) as raised,
        scopes.task(
            "undeclared", TaskKind.FIXTURE, "Undeclared", FixedTaskChildren(), 0
        ),
    ):
        pass

    assert raised.value == UndeclaredTaskChildError("undeclared")


def test_passing_task_rejects_incomplete_fixed_regions() -> None:
    roots = RecordingRoots()
    times = iter((1.0, 2.0))
    scopes = TaskScopes(roots, lambda: next(times))

    with (
        pytest.raises(IncompleteTaskChildrenError) as raised,
        scopes.root(
            "run",
            TaskKind.SUITE,
            "Conformance",
            FixedTaskChildren.equal("prepare", "judge"),
        ) as task,
    ):
        task.complete_child("prepare", "Prepared")

    assert raised.value == IncompleteTaskChildrenError(("run",), ("judge",))
    assert tuple(task.snapshot() for task in roots.roots) == (
        TaskSnapshot(
            path=("run",),
            kind=TaskKind.SUITE,
            description="Conformance",
            detail="Failed",
            completed=1,
            total=2,
            outcome=TaskOutcome.FAILED,
            revision=2,
            started_at=1.0,
            finished_at=2.0,
            children=(),
            child_progress=TaskChildrenSnapshot(
                kind=TaskChildrenKind.FIXED,
                sealed=True,
                maximum=None,
                children=(
                    TaskChildSnapshot("prepare", 1.0, False, True),
                    TaskChildSnapshot("judge", 1.0, False, False),
                ),
            ),
        ),
    )


def test_nested_incomplete_task_preserves_the_cause_and_finishes_its_tree() -> None:
    roots = RecordingRoots()
    scopes = TaskScopes(roots)

    with (
        pytest.raises(IncompleteTaskChildrenError) as raised,
        scopes.root(
            "run",
            TaskKind.SUITE,
            "Conformance",
            FixedTaskChildren.equal("fixture"),
        ),
        scopes.task(
            "fixture",
            TaskKind.FIXTURE,
            "Fixture",
            FixedTaskChildren.equal("prepare", "judge"),
            0,
        ) as child,
    ):
        child.complete_child("prepare", "Prepared")

    assert raised.value == IncompleteTaskChildrenError(("run", "fixture"), ("judge",))
    assert tuple(
        (root.outcome, tuple(child.outcome for child in root.children))
        for root in roots.roots
    ) == ((TaskOutcome.FAILED, (TaskOutcome.FAILED,)),)


def test_task_rejects_duplicate_child_names() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root("run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()):
        with scopes.task("worker", TaskKind.FIXTURE, "Worker", FixedTaskChildren(), 0):
            pass

        with (
            pytest.raises(DuplicateTaskChildError) as raised,
            scopes.task("worker", TaskKind.FIXTURE, "Worker", FixedTaskChildren(), 1),
        ):
            pass

    assert raised.value == DuplicateTaskChildError(("run",), "worker")


def test_task_rejects_duplicate_child_orders() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root("run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()):
        with scopes.task("first", TaskKind.FIXTURE, "First", FixedTaskChildren(), 0):
            pass

        with (
            pytest.raises(DuplicateTaskChildOrderError) as raised,
            scopes.task("second", TaskKind.FIXTURE, "Second", FixedTaskChildren(), 0),
        ):
            pass

    assert raised.value == DuplicateTaskChildOrderError(
        ("run",),
        0,
        "first",
        "second",
    )


def test_finished_task_rejects_mutation() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        task.complete_child("work", "Finished")
        task.finish(TaskOutcome.PASSED, "Complete")

        with pytest.raises(FinishedTaskMutationError) as raised:
            task.complete_child("work", "Unexpected")

    assert raised.value == FinishedTaskMutationError(("run",))


def test_child_region_cannot_be_completed_twice() -> None:
    scopes = TaskScopes(RecordingRoots())

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        task.complete_child("work", "Finished")

        with pytest.raises(TaskChildAlreadyCompletedError) as raised:
            task.complete_child("work", "Finished again")

    assert raised.value == TaskChildAlreadyCompletedError("work")


def test_parent_cannot_finish_while_a_child_is_running() -> None:
    scopes = TaskScopes(RecordingRoots())

    with (
        scopes.root(
            "run",
            TaskKind.SUITE,
            "Conformance",
            FixedTaskChildren.equal("worker"),
        ) as root,
        scopes.task("worker", TaskKind.FIXTURE, "Worker", FixedTaskChildren(), 0),
        pytest.raises(RunningTaskChildrenError) as raised,
    ):
        root.finish(TaskOutcome.PASSED, "Complete")

    assert raised.value == RunningTaskChildrenError(
        ("run",),
        (("run", "worker"),),
    )


def test_cancelled_finish_cancels_running_descendants() -> None:
    """An interrupt can finish a parent while its worker threads still run."""

    scopes = TaskScopes(RecordingRoots())

    with (
        scopes.root(
            "run",
            TaskKind.SUITE,
            "Conformance",
            FixedTaskChildren.equal("worker"),
        ) as root,
        scopes.task(
            "worker",
            TaskKind.FIXTURE,
            "Worker",
            FixedTaskChildren.equal("phase"),
            0,
        ) as worker,
        scopes.task("phase", TaskKind.PHASE, "Phase", FixedTaskChildren(), 0) as phase,
    ):
        root.finish(TaskOutcome.CANCELLED, "Interrupted")

    assert (
        (root.outcome, root.snapshot().detail),
        (worker.outcome, worker.snapshot().detail),
        (phase.outcome, phase.snapshot().detail),
    ) == (
        (TaskOutcome.CANCELLED, "Interrupted"),
        (TaskOutcome.CANCELLED, "Cancelled"),
        (TaskOutcome.CANCELLED, "Cancelled"),
    )


def test_root_cannot_be_nested() -> None:
    scopes = TaskScopes(RecordingRoots())

    with (
        scopes.root("run", TaskKind.SUITE, "Conformance"),
        pytest.raises(NestedRootTaskError) as raised,
        scopes.root("nested", TaskKind.SUITE, "Nested"),
    ):
        pass

    assert raised.value == NestedRootTaskError("nested", ("run",))


def test_async_cancellation_marks_the_task_as_cancelled() -> None:
    roots = RecordingRoots()
    times = iter((1.0, 2.0))
    scopes = TaskScopes(roots, lambda: next(times))

    with (
        pytest.raises(asyncio.CancelledError),
        scopes.root("run", TaskKind.SUITE, "Conformance", UnboundedTaskChildren()),
    ):
        raise asyncio.CancelledError

    assert tuple(task.snapshot() for task in roots.roots) == (
        TaskSnapshot(
            path=("run",),
            kind=TaskKind.SUITE,
            description="Conformance",
            detail="Cancelled",
            completed=0,
            total=0,
            outcome=TaskOutcome.CANCELLED,
            revision=1,
            started_at=1.0,
            finished_at=2.0,
            children=(),
            child_progress=TaskChildrenSnapshot(
                kind=TaskChildrenKind.UNBOUNDED,
                sealed=True,
                maximum=None,
                children=(),
            ),
        ),
    )
