import json
import time
from dataclasses import replace
from io import StringIO
from pathlib import Path

import pytest
from rich.console import Console

from claude_prompt_conformance import models
from claude_prompt_conformance.frontend import (
    CatalogueEntry,
    CheckPresentation,
    CriterionPresentation,
    JsonFrontend,
    ResultPresentation,
    catalogue_entries,
    parse_interactive_selection,
    result_presentation,
)
from claude_prompt_conformance.models import (
    Fixture,
    ImprovementAborted,
    ImprovementFinished,
    SuiteFinished,
    SuiteInterrupted,
)
from claude_prompt_conformance.progress import (
    TaskActivity,
    TaskKind,
    TaskOutcome,
    TaskScopes,
    TaskSnapshot,
)
from claude_prompt_conformance.task_children import (
    FixedTaskChildren,
    TaskChildrenKind,
    TaskChildrenSnapshot,
    TaskChildSnapshot,
)
from claude_prompt_conformance.task_frontend import (
    RichTaskView,
    displayed_progress,
    frame_rows,
    progress_count,
    render_frame,
    task_completion_fraction,
    task_detail,
)

from .helpers import (
    candidate_result,
    judgement,
    make_fixture,
    verification_results,
    workspace_evidence,
)


def fixtures(tmp_path: Path) -> tuple[Fixture, ...]:
    return (
        make_fixture(tmp_path, name="one", category="clarity", tags=("actors",)),
        make_fixture(tmp_path, name="two", category="precision", tags=("shell",)),
    )


def fixed_progress(
    *children: TaskChildSnapshot,
) -> TaskChildrenSnapshot:
    return TaskChildrenSnapshot(
        kind=TaskChildrenKind.FIXED,
        sealed=True,
        maximum=None,
        children=children,
    )


def test_json_frontend_emits_a_structured_event() -> None:
    stream = StringIO()
    frontend = JsonFrontend(stream)
    frontend.emit(SuiteFinished(2, 0, 0, 0, Path("results"), Path("run.json")))
    assert json.loads(stream.getvalue()) == {
        "event": "SuiteFinished",
        "failed": 0,
        "invalid": 0,
        "output": "results",
        "passed": 2,
        "run_metadata": "run.json",
        "stale": 0,
    }


def test_json_frontend_emits_a_structured_interruption() -> None:
    stream = StringIO()
    frontend = JsonFrontend(stream)

    frontend.emit(SuiteInterrupted(Path("results")))

    assert json.loads(stream.getvalue()) == {
        "event": "SuiteInterrupted",
        "output": "results",
    }


def test_json_frontend_emits_a_complete_improvement_result() -> None:
    stream = StringIO()
    frontend = JsonFrontend(stream)

    frontend.emit(
        ImprovementFinished(
            accepted_proposals=1,
            attempted_proposals=2,
            reserved_checks_accepted=True,
            output=Path("results"),
            winner_patch=Path("results/prompt-variants/winner.patch"),
        )
    )

    assert json.loads(stream.getvalue()) == {
        "accepted_proposals": 1,
        "attempted_proposals": 2,
        "event": "ImprovementFinished",
        "reserved_checks_accepted": True,
        "output": "results",
        "winner_patch": "results/prompt-variants/winner.patch",
    }


def test_json_frontend_emits_a_structured_improvement_abort() -> None:
    stream = StringIO()
    frontend = JsonFrontend(stream)

    frontend.emit(ImprovementAborted(Path("results")))

    assert json.loads(stream.getvalue()) == {
        "event": "ImprovementAborted",
        "output": "results",
    }


def test_json_frontend_emits_complete_task_changes() -> None:
    stream = StringIO()
    frontend = JsonFrontend(stream)
    times = iter((1.0, 2.0, 3.0, 4.0))
    scopes = TaskScopes(frontend, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("fixture"),
    ) as root:
        with scopes.task(
            "fixture", TaskKind.FIXTURE, "Fixture", FixedTaskChildren(), 0
        ):
            pass
        root.finish(TaskOutcome.PASSED, "All fixtures passed")

    records = tuple(json.loads(line) for line in stream.getvalue().splitlines())
    assert records == (
        {
            "change": "added",
            "event": "TaskObserved",
            "task": {
                "active_activities": 0,
                "activities": 0,
                "activity": None,
                "child_progress": {
                    "children": [
                        {
                            "completed": False,
                            "name": "fixture",
                            "registered": False,
                            "weight": 1.0,
                        }
                    ],
                    "kind": "fixed",
                    "maximum": None,
                    "sealed": True,
                },
                "children": [],
                "completed": 0,
                "description": "Conformance",
                "detail": "Waiting",
                "finished_at": None,
                "kind": "suite",
                "outcome": None,
                "path": ["run"],
                "revision": 0,
                "started_at": 1.0,
                "total": 1,
            },
        },
        {
            "change": "added",
            "event": "TaskObserved",
            "task": {
                "active_activities": 0,
                "activities": 0,
                "activity": None,
                "child_progress": {
                    "children": [],
                    "kind": "fixed",
                    "maximum": None,
                    "sealed": True,
                },
                "children": [],
                "completed": 0,
                "description": "Fixture",
                "detail": "Waiting",
                "finished_at": None,
                "kind": "fixture",
                "outcome": None,
                "path": ["run", "fixture"],
                "revision": 0,
                "started_at": 2.0,
                "total": 0,
            },
        },
        {
            "change": "finished",
            "event": "TaskObserved",
            "task": {
                "active_activities": 0,
                "activities": 0,
                "activity": None,
                "child_progress": {
                    "children": [],
                    "kind": "fixed",
                    "maximum": None,
                    "sealed": True,
                },
                "children": [],
                "completed": 0,
                "description": "Fixture",
                "detail": "Completed",
                "finished_at": 3.0,
                "kind": "fixture",
                "outcome": "completed",
                "path": ["run", "fixture"],
                "revision": 1,
                "started_at": 2.0,
                "total": 0,
            },
        },
        {
            "change": "updated",
            "event": "TaskObserved",
            "task": {
                "active_activities": 0,
                "activities": 0,
                "activity": None,
                "child_progress": {
                    "children": [
                        {
                            "completed": True,
                            "name": "fixture",
                            "registered": True,
                            "weight": 1.0,
                        }
                    ],
                    "kind": "fixed",
                    "maximum": None,
                    "sealed": True,
                },
                "children": [
                    {
                        "active_activities": 0,
                        "activities": 0,
                        "activity": None,
                        "child_progress": {
                            "children": [],
                            "kind": "fixed",
                            "maximum": None,
                            "sealed": True,
                        },
                        "children": [],
                        "completed": 0,
                        "description": "Fixture",
                        "detail": "Completed",
                        "finished_at": 3.0,
                        "kind": "fixture",
                        "outcome": "completed",
                        "path": ["run", "fixture"],
                        "revision": 1,
                        "started_at": 2.0,
                        "total": 0,
                    }
                ],
                "completed": 1,
                "description": "Conformance",
                "detail": "Waiting",
                "finished_at": None,
                "kind": "suite",
                "outcome": None,
                "path": ["run"],
                "revision": 1,
                "started_at": 1.0,
                "total": 1,
            },
        },
        {
            "change": "finished",
            "event": "TaskObserved",
            "task": {
                "active_activities": 0,
                "activities": 0,
                "activity": None,
                "child_progress": {
                    "children": [
                        {
                            "completed": True,
                            "name": "fixture",
                            "registered": True,
                            "weight": 1.0,
                        }
                    ],
                    "kind": "fixed",
                    "maximum": None,
                    "sealed": True,
                },
                "children": [
                    {
                        "active_activities": 0,
                        "activities": 0,
                        "activity": None,
                        "child_progress": {
                            "children": [],
                            "kind": "fixed",
                            "maximum": None,
                            "sealed": True,
                        },
                        "children": [],
                        "completed": 0,
                        "description": "Fixture",
                        "detail": "Completed",
                        "finished_at": 3.0,
                        "kind": "fixture",
                        "outcome": "completed",
                        "path": ["run", "fixture"],
                        "revision": 1,
                        "started_at": 2.0,
                        "total": 0,
                    }
                ],
                "completed": 1,
                "description": "Conformance",
                "detail": "All fixtures passed",
                "finished_at": 4.0,
                "kind": "suite",
                "outcome": "passed",
                "path": ["run"],
                "revision": 2,
                "started_at": 1.0,
                "total": 1,
            },
        },
    )


def test_rich_task_view_collapses_a_successful_tree_into_its_root() -> None:
    phase = TaskSnapshot(
        path=("run", "fixture", "phase"),
        kind=TaskKind.PHASE,
        description="Phase",
        detail="Complete",
        completed=0,
        total=0,
        outcome=TaskOutcome.PASSED,
        revision=1,
        started_at=2.0,
        finished_at=2.5,
        children=(),
        child_progress=fixed_progress(),
    )
    child = TaskSnapshot(
        path=("run", "fixture"),
        kind=TaskKind.FIXTURE,
        description="Fixture",
        detail="Complete",
        completed=1,
        total=1,
        outcome=TaskOutcome.PASSED,
        revision=1,
        started_at=2.0,
        finished_at=3.0,
        children=(phase,),
        child_progress=fixed_progress(TaskChildSnapshot("phase", 1.0, True, True)),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="All fixtures passed",
        completed=1,
        total=1,
        outcome=TaskOutcome.PASSED,
        revision=1,
        started_at=1.0,
        finished_at=4.0,
        children=(child,),
        child_progress=fixed_progress(TaskChildSnapshot("fixture", 1.0, True, True)),
    )
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(root, 120, 40, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "✓  Prompt conformance               ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   0:00:03                  All fixtures passed",
    ]


def test_rich_task_view_collapses_skipped_descendants_of_a_successful_root() -> None:
    skipped = TaskSnapshot(
        path=("run", "reserved"),
        kind=TaskKind.EVALUATION,
        description="Reserved examples",
        detail="No prompt accepted",
        completed=0,
        total=0,
        outcome=TaskOutcome.SKIPPED,
        revision=1,
        started_at=2.0,
        finished_at=3.0,
        children=(),
        child_progress=fixed_progress(),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.IMPROVEMENT,
        description="Prompt improvement",
        detail="Search complete",
        completed=1,
        total=1,
        outcome=TaskOutcome.PASSED,
        revision=2,
        started_at=1.0,
        finished_at=4.0,
        children=(skipped,),
        child_progress=fixed_progress(TaskChildSnapshot("reserved", 1.0, True, True)),
    )
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(root, 120, 40, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "✓  Prompt improvement               ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   0:00:03                      Search complete",
    ]


def test_rich_task_view_keeps_failed_descendants_of_a_successful_root_visible() -> None:
    child = TaskSnapshot(
        path=("run", "fixture"),
        kind=TaskKind.FIXTURE,
        description="Fixture",
        detail="Judge rejected the work",
        completed=1,
        total=1,
        outcome=TaskOutcome.FAILED,
        revision=1,
        started_at=2.0,
        finished_at=3.0,
        children=(),
        child_progress=fixed_progress(TaskChildSnapshot("work", 1.0, False, True)),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Winning prompt accepted",
        completed=1,
        total=1,
        outcome=TaskOutcome.PASSED,
        revision=1,
        started_at=1.0,
        finished_at=4.0,
        children=(child,),
        child_progress=fixed_progress(TaskChildSnapshot("fixture", 1.0, True, True)),
    )
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(root, 120, 40, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "✓  Prompt conformance               ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   0:00:03              Winning prompt accepted",
        "✗  └── Fixture                      ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   0:00:01              Judge rejected the work",
    ]


def test_rich_task_view_renders_nested_live_spinners_and_progress_bars() -> None:
    child = TaskSnapshot(
        path=("run", "fixture"),
        kind=TaskKind.FIXTURE,
        description="Fixture",
        detail="Judging",
        completed=1,
        total=2,
        outcome=None,
        revision=1,
        started_at=2.0,
        finished_at=None,
        children=(),
        child_progress=fixed_progress(
            TaskChildSnapshot("prepare", 1.0, False, True),
            TaskChildSnapshot("judge", 1.0, False, False),
        ),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Running fixtures",
        completed=0,
        total=1,
        outcome=None,
        revision=0,
        started_at=1.0,
        finished_at=None,
        children=(child,),
        child_progress=fixed_progress(TaskChildSnapshot("fixture", 1.0, True, False)),
    )
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(root, 120, 40, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "⠋  Prompt conformance               ━━━━━━━━━━━━────────────          0/1   0:00:03                     Running fixtures",
        "⠋  └── Fixture                      ━━━━━━━━━━━━────────────          1/2   0:00:02                              Judging",
    ]


def test_live_task_detail_distinguishes_tool_progress_from_completion() -> None:
    activity = TaskActivity(
        identifier="tool-3",
        description="Bash: Check the repository",
        sequence=3,
        started_at=5.0,
        observed_at=120.0,
        elapsed_seconds=115,
        heartbeat=True,
    )
    candidate = TaskSnapshot(
        path=("run", "fixture", "candidate"),
        kind=TaskKind.PHASE,
        description="Asking the candidate agent",
        detail="Working",
        completed=0,
        total=None,
        outcome=None,
        revision=4,
        started_at=4.0,
        finished_at=None,
        children=(),
        child_progress=TaskChildrenSnapshot(
            kind=TaskChildrenKind.UNBOUNDED,
            sealed=False,
            maximum=None,
            children=(),
        ),
        activity=activity,
        activities=3,
        active_activities=1,
    )
    fixture = TaskSnapshot(
        path=("run", "fixture"),
        kind=TaskKind.FIXTURE,
        description="Fixture",
        detail="Running",
        completed=1,
        total=5,
        outcome=None,
        revision=1,
        started_at=2.0,
        finished_at=None,
        children=(candidate,),
        child_progress=fixed_progress(
            TaskChildSnapshot("prepare", 1.0, False, True),
            TaskChildSnapshot("calibrate", 1.0, False, False),
            TaskChildSnapshot("candidate", 1.0, True, False),
            TaskChildSnapshot("verify", 1.0, False, False),
            TaskChildSnapshot("judge", 1.0, False, False),
        ),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Running",
        completed=0,
        total=1,
        outcome=None,
        revision=0,
        started_at=1.0,
        finished_at=None,
        children=(fixture,),
        child_progress=fixed_progress(TaskChildSnapshot("fixture", 1.0, True, False)),
    )
    assert (
        task_detail(root, lambda: 130.0),
        task_detail(fixture, lambda: 130.0),
        task_detail(candidate, lambda: 130.0),
    ) == (
        "Running",
        "Running",
        "Bash: Check the repository · active 2:05 · heartbeat 0:10 ago",
    )


def test_visual_progress_uses_weighted_recursive_child_regions() -> None:
    phase = TaskSnapshot(
        path=("run", "fixture", "phase"),
        kind=TaskKind.PHASE,
        description="Phase",
        detail="Running",
        completed=1,
        total=2,
        outcome=None,
        revision=1,
        started_at=2.0,
        finished_at=None,
        children=(),
        child_progress=fixed_progress(
            TaskChildSnapshot("analyse", 1.0, False, True),
            TaskChildSnapshot("implement", 1.0, False, False),
        ),
    )
    fixture = TaskSnapshot(
        path=("run", "fixture"),
        kind=TaskKind.FIXTURE,
        description="Fixture",
        detail="Running",
        completed=1,
        total=2,
        outcome=None,
        revision=2,
        started_at=1.0,
        finished_at=None,
        children=(phase,),
        child_progress=fixed_progress(
            TaskChildSnapshot("prepare", 10.0, False, True),
            TaskChildSnapshot("phase", 90.0, True, False),
        ),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Running",
        completed=0,
        total=2,
        outcome=None,
        revision=0,
        started_at=0.0,
        finished_at=None,
        children=(fixture,),
        child_progress=fixed_progress(
            TaskChildSnapshot("fixture", 90.0, True, False),
            TaskChildSnapshot("archive", 10.0, False, False),
        ),
    )

    assert displayed_progress(root) == (0, 2)
    assert (
        task_completion_fraction(phase),
        task_completion_fraction(fixture),
        task_completion_fraction(root),
    ) == pytest.approx((0.5, 0.55, 0.495))


def test_bounded_visual_progress_reserves_space_for_the_maximum() -> None:
    child = TaskSnapshot(
        path=("run", "first"),
        kind=TaskKind.FIXTURE,
        description="First fixture",
        detail="Running",
        completed=1,
        total=2,
        outcome=None,
        revision=1,
        started_at=1.0,
        finished_at=None,
        children=(),
        child_progress=fixed_progress(
            TaskChildSnapshot("prepare", 1.0, False, True),
            TaskChildSnapshot("judge", 1.0, False, False),
        ),
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Running",
        completed=0,
        total=4,
        outcome=None,
        revision=0,
        started_at=0.0,
        finished_at=None,
        children=(child,),
        child_progress=TaskChildrenSnapshot(
            kind=TaskChildrenKind.BOUNDED,
            sealed=False,
            maximum=4,
            children=(TaskChildSnapshot("first", 1.0, True, False),),
        ),
    )

    assert (
        displayed_progress(root),
        task_completion_fraction(root),
    ) == ((0, 4), 0.125)


def test_unbounded_visual_progress_is_indeterminate_until_sealed() -> None:
    open_snapshot = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Discovering work",
        detail="Running",
        completed=2,
        total=None,
        outcome=None,
        revision=2,
        started_at=0.0,
        finished_at=None,
        children=(),
        child_progress=TaskChildrenSnapshot(
            kind=TaskChildrenKind.UNBOUNDED,
            sealed=False,
            maximum=None,
            children=(
                TaskChildSnapshot("first", 1.0, False, True),
                TaskChildSnapshot("second", 1.0, False, True),
            ),
        ),
    )
    sealed_snapshot = replace(
        open_snapshot,
        total=2,
        child_progress=replace(open_snapshot.child_progress, sealed=True),
    )

    assert (
        displayed_progress(open_snapshot),
        progress_count(open_snapshot),
        task_completion_fraction(open_snapshot),
        displayed_progress(sealed_snapshot),
        progress_count(sealed_snapshot),
        task_completion_fraction(sealed_snapshot),
    ) == ((2, None), "2 complete", None, (2, 2), "2/2", 1.0)

    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None, no_color=False)
    console.print(render_frame(open_snapshot, 120, 40, lambda: 1.0))

    assert stream.getvalue().splitlines() == [
        "⠹  Discovering work                 ────────────━━━─────────   2 complete   0:00:01                              Running",
    ]


def test_rich_task_view_refreshes_elapsed_time_without_backend_changes() -> None:
    snapshot = TaskSnapshot(
        path=("phase",),
        kind=TaskKind.PHASE,
        description="Phase",
        detail="Working",
        completed=0,
        total=1,
        outcome=None,
        revision=0,
        started_at=1.0,
        finished_at=None,
        children=(),
        child_progress=fixed_progress(TaskChildSnapshot("work", 1.0, False, False)),
    )
    times = iter((4.0, 6.0))
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(snapshot, 120, 40, lambda: next(times)))
    console.print(render_frame(snapshot, 120, 40, lambda: next(times)))

    assert stream.getvalue().splitlines() == [
        "⠋  Phase                            ────────────────────────          0/1   0:00:03                              Working",
        "⠴  Phase                            ────────────────────────          0/1   0:00:05                              Working",
    ]


def test_rich_task_view_retains_the_finished_root() -> None:
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)
    times = iter((1.0, 2.0))
    view = RichTaskView(console, lambda: 9.0, tick_seconds=3600.0)
    scopes = TaskScopes(view, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        task.complete_child("work", "Finished")

    assert stream.getvalue() == (
        "●  Conformance                      ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   "
        "0:00:01                            Completed"
    )


def test_rich_task_view_pins_an_announcement_above_the_tree() -> None:
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)
    times = iter((1.0, 2.0))
    view = RichTaskView(console, lambda: 9.0, tick_seconds=3600.0)
    scopes = TaskScopes(view, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        view.announce("Interrupt received: stopping agents.")
        task.complete_child("work", "Finished")

    assert stream.getvalue() == (
        "Interrupt received: stopping agents.\n"
        "●  Conformance                      ━━━━━━━━━━━━━━━━━━━━━━━━          1/1   "
        "0:00:01                            Completed"
    )


def test_rich_task_view_brackets_every_terminal_paint_atomically() -> None:
    stream = StringIO()
    console = Console(
        file=stream,
        width=120,
        height=30,
        force_terminal=True,
        color_system=None,
    )
    times = iter((1.0, 2.0))
    view = RichTaskView(console, lambda: 9.0, tick_seconds=3600.0)
    scopes = TaskScopes(view, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        task.complete_child("work", "Finished")

    value = stream.getvalue()
    paints = value.split("\x1b[?2026h")[1:]
    assert (
        len(paints),
        [paint.count("\x1b[?2026l") for paint in paints],
        "Conformance" in paints[-1] and "Completed" in paints[-1],
    ) == (3, [1, 1, 1], True)


def test_rich_task_view_skips_repainting_still_frames() -> None:
    stream = StringIO()
    console = Console(
        file=stream,
        width=120,
        height=30,
        force_terminal=True,
        color_system=None,
    )
    times = iter((1.0, 2.0))
    view = RichTaskView(console, lambda: 9.0, tick_seconds=0.001)
    scopes = TaskScopes(view, lambda: next(times))

    with scopes.root(
        "run",
        TaskKind.SUITE,
        "Conformance",
        FixedTaskChildren.equal("work"),
    ) as task:
        # The ticker fires many times here, but the view clock is fixed and
        # no task changes, so every tick fingerprints the same frame.
        time.sleep(0.05)
        painted_during_stillness = stream.getvalue().count("\x1b[?2026h")
        task.complete_child("work", "Finished")

    assert painted_during_stillness == 1


def evaluation_with_samples() -> TaskSnapshot:
    """An evaluation whose five samples exceed a small terminal's height."""

    samples = tuple(
        TaskSnapshot(
            path=("run", "eval", f"sample-{index:02}"),
            kind=TaskKind.SAMPLE,
            description=f"Sample {index}",
            detail="Running tests",
            completed=0,
            total=3,
            outcome=TaskOutcome.PASSED if index <= 2 else None,
            revision=1,
            started_at=2.0,
            finished_at=3.0 if index <= 2 else None,
            children=(),
            child_progress=fixed_progress(),
            activity=(
                TaskActivity(
                    identifier=f"tool-{index}",
                    description=f"Bash: fixture work {index}",
                    sequence=index,
                    started_at=2.0,
                    observed_at=2.0 + index,
                    elapsed_seconds=0,
                    heartbeat=False,
                )
                if index > 2
                else None
            ),
        )
        for index in range(1, 6)
    )
    evaluation = TaskSnapshot(
        path=("run", "eval"),
        kind=TaskKind.EVALUATION,
        description="Test the current prompt",
        detail="Running samples",
        completed=2,
        total=5,
        outcome=None,
        revision=1,
        started_at=1.0,
        finished_at=None,
        children=samples,
        child_progress=fixed_progress(
            *(
                TaskChildSnapshot(f"sample-{index:02}", 1.0, True, index <= 2)
                for index in range(1, 6)
            )
        ),
    )
    return TaskSnapshot(
        path=("run",),
        kind=TaskKind.IMPROVEMENT,
        description="Prompt improvement",
        detail="Searching",
        completed=0,
        total=3,
        outcome=None,
        revision=1,
        started_at=0.0,
        finished_at=None,
        children=(evaluation,),
        child_progress=fixed_progress(
            TaskChildSnapshot("eval", 1.0, True, False),
            TaskChildSnapshot("drafts", 1.0, False, False),
            TaskChildSnapshot("reserved", 1.0, False, False),
        ),
    )


def test_frame_rows_fold_deep_levels_into_glyph_strips() -> None:
    rows, hidden = frame_rows(evaluation_with_samples(), 3)

    assert (
        [
            (
                row.snapshot.path,
                row.guide,
                tuple(glyph for glyph, _ in row.strip),
                None if row.promoted is None else row.promoted.identifier,
            )
            for row in rows
        ],
        hidden,
    ) == (
        [
            (("run",), "", (), None),
            (("run", "eval"), "└── ", ("✓", "✓", "◐", "◐", "◐"), "tool-5"),
        ],
        0,
    )


def test_folded_rows_render_the_strip_and_the_latest_activity() -> None:
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(evaluation_with_samples(), 120, 4, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "⠋  Prompt improvement               ━━━─────────────────────          0/3   0:00:04                            Searching",
        "⠋  └── Test the current prom… ✓✓◐◐◐ ━━━━━━━━━───────────────          2/5   0:00:03   Bash: fixture work 5 · active 0:02",
    ]


def test_frames_taller_than_the_shallowest_layout_drop_tail_rows() -> None:
    children = tuple(
        TaskSnapshot(
            path=("run", f"fixture-{index}"),
            kind=TaskKind.FIXTURE,
            description=f"Fixture {index}",
            detail="Running",
            completed=0,
            total=1,
            outcome=None,
            revision=1,
            started_at=2.0,
            finished_at=None,
            children=(),
            child_progress=fixed_progress(TaskChildSnapshot("work", 1.0, False, False)),
        )
        for index in range(6)
    )
    root = TaskSnapshot(
        path=("run",),
        kind=TaskKind.SUITE,
        description="Prompt conformance",
        detail="Running",
        completed=0,
        total=6,
        outcome=None,
        revision=1,
        started_at=1.0,
        finished_at=None,
        children=children,
        child_progress=fixed_progress(
            *(
                TaskChildSnapshot(f"fixture-{index}", 1.0, True, False)
                for index in range(6)
            )
        ),
    )
    stream = StringIO()
    console = Console(file=stream, width=120, color_system=None)

    console.print(render_frame(root, 120, 6, lambda: 4.0))

    assert stream.getvalue().splitlines() == [
        "⠋  Prompt conformance               ────────────────────────          0/6   0:00:03                              Running",
        "⠋  ├── Fixture 0                    ────────────────────────          0/1   0:00:02                              Running",
        "⠋  ├── Fixture 1                    ────────────────────────          0/1   0:00:02                              Running",
        "⠋  ├── Fixture 2                    ────────────────────────          0/1   0:00:02                              Running",
        "… 3 more",
    ]


def test_result_presentation_shows_correction_only_for_failures(
    tmp_path: Path,
) -> None:
    artefacts = tmp_path / "artefacts"
    artefacts.mkdir()
    (artefacts / "commits.txt").write_text("commit abc\n\n    Explain the fix.\n")
    result = models.TestResult(
        candidate=candidate_result(artefacts),
        evidence=workspace_evidence("base", "head", artefacts),
        verification=verification_results("head", artefacts),
        judgement=judgement(False, "head"),
        calibration=(),
    )

    assert tuple(
        result_presentation(
            models.TestFinished(
                fixture_name="example",
                status=(
                    models.TestStatus.PASSED if passed else models.TestStatus.FAILED
                ),
                summary="assessment",
                failures=() if passed else ("works: assessment",),
                result=replace(result, judgement=judgement(passed, "head")),
            )
        )
        for passed in (True, False)
    ) == (
        ResultPresentation(
            response="candidate response",
            changelog="commit abc\n\n    Explain the fix.",
            changed_files=("file",),
            recommendation=None,
            counterfactual=None,
            corrected_response=None,
            failed_criteria=(),
            checks=(CheckPresentation("check", True),),
        ),
        ResultPresentation(
            response="candidate response",
            changelog="commit abc\n\n    Explain the fix.",
            changed_files=("file",),
            recommendation="Apply the fix.",
            counterfactual="diff --git a/file b/file",
            corrected_response="Fixed and checked.",
            failed_criteria=(CriterionPresentation("works", "assessment"),),
            checks=(CheckPresentation("check", True),),
        ),
    )


def test_catalogue_entries_describe_every_fixture(tmp_path: Path) -> None:
    assert catalogue_entries(fixtures(tmp_path)) == (
        CatalogueEntry(
            number=1,
            name="one",
            kind="author",
            use="working",
            category="clarity",
            description="Investigate a representative repository failure.",
            tags=("actors",),
        ),
        CatalogueEntry(
            number=2,
            name="two",
            kind="author",
            use="working",
            category="precision",
            description="Investigate a representative repository failure.",
            tags=("shell",),
        ),
    )


@pytest.mark.parametrize(
    ("answer", "expected"),
    [
        ("all", ("one", "two")),
        ("1,2", ("one", "two")),
        ("category:clarity", ("one",)),
        ("tag:shell", ("two",)),
    ],
)
def test_parse_interactive_selection(
    tmp_path: Path, answer: str, expected: tuple[str, ...]
) -> None:
    assert parse_interactive_selection(answer, fixtures(tmp_path)) == expected
