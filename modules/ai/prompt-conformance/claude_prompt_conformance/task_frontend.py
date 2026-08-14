"""Presentation adapters for scoped task runs."""

import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from threading import Event, Lock, RLock, Thread

from rich.console import Console, ConsoleOptions, ConsoleRenderable, RenderResult
from rich.live import Live
from rich.segment import ControlType, Segment
from rich.text import Text

from .progress import (
    TaskActivity,
    TaskChange,
    TaskChangeKind,
    TaskOutcome,
    TaskRun,
    TaskSnapshot,
)
from .protocols.progress import TaskObserved
from .task_children import TaskChildrenKind


class JsonTaskView:
    """Project task signals into typed streaming records."""

    def __init__(self, write: Callable[[TaskObserved], None]) -> None:
        self._write = write

    def observe(self, root: TaskRun) -> None:
        """Attach to a root and emit its initial state and later changes."""

        self._write(TaskObserved(TaskChangeKind.ADDED, root.snapshot()))
        root.signals.changed.connect(self._changed)

    def _changed(self, change: TaskChange) -> None:
        self._write(TaskObserved(change.kind, change.task))


_SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
_SPINNER_INTERVAL_SECONDS = 0.08

_STATUS_WIDTH = 2
_BAR_WIDTH = 24
_COUNT_WIDTH = 12
_ELAPSED_WIDTH = 9
_DETAIL_WIDTH = 36
_CELL_GAPS = 5
_MINIMUM_DESCRIPTION_WIDTH = 16
_FIXED_ROW_WIDTH = (
    _STATUS_WIDTH + _BAR_WIDTH + _COUNT_WIDTH + _ELAPSED_WIDTH + _DETAIL_WIDTH
) + _CELL_GAPS

_MINIMUM_ROW_BUDGET = 4
_MAXIMUM_STRIP_GLYPHS = 12

_SYNCHRONISED_UPDATE_START = "\x1b[?2026h"
_SYNCHRONISED_UPDATE_END = "\x1b[?2026l"


class _RawControl:
    """Emit a terminal control sequence Rich has no ControlType for."""

    def __init__(self, code: str) -> None:
        # The control marker must be truthy: Rich measures a segment whose
        # control sequence is empty as visible text, and line cropping would
        # then count the escape code against the line width and cut it off.
        # Cursor-forward-by-zero does nothing on the legacy Windows path,
        # which is the only consumer of the marker's contents.
        self._segment = Segment(code, None, ((ControlType.CURSOR_FORWARD, 0),))

    def __rich_console__(
        self,
        console: Console,
        options: ConsoleOptions,
    ) -> RenderResult:
        yield self._segment


class SynchronisedLive(Live):
    """A live display which paints each frame as one atomic terminal update.

    Every paint is wrapped in the terminal's synchronised-update mode (DEC
    private mode 2026), so a repaint never shows the erased region between
    clearing and rewriting. Terminals without the mode ignore the sequences.
    """

    def __init__(self, console: Console) -> None:
        super().__init__(Text(), console=console, auto_refresh=False)

    def process_renderables(
        self,
        renderables: list[ConsoleRenderable],
    ) -> list[ConsoleRenderable]:
        renderables = super().process_renderables(renderables)
        if renderables and self.console.is_terminal:
            return [
                _RawControl(_SYNCHRONISED_UPDATE_START),
                *renderables,
                _RawControl(_SYNCHRONISED_UPDATE_END),
            ]
        return renderables


class RichTaskView:
    """Render task snapshots through one clock-driven Rich live display.

    Task changes only mark the frame dirty. A ticker thread paints at the
    frame rate, and a paint whose fingerprint matches the previous one is
    skipped before the frame is built, so a still display costs nothing and
    a change reaches the terminal within one tick.

    The live display only ever renders prebuilt text, never the task tree.
    A finishing task publishes while the task-tree lock is held, so the tree
    may only be read outside the paint lock; building frames up front keeps
    the two locks from ever being taken in opposite orders.
    """

    def __init__(
        self,
        console: Console,
        clock: Callable[[], float] = time.monotonic,
        tick_seconds: float = 1 / 60,
    ) -> None:
        self._console = console
        self._clock = clock
        self._tick_seconds = tick_seconds
        self._root: TaskRun | None = None
        self._revision = 0
        self._banner: str | None = None
        self._lock = RLock()
        self._paint_lock = Lock()
        self._painted: object = None
        self._stop_ticker = Event()
        self._live = SynchronisedLive(console)

    def observe(self, root: TaskRun) -> None:
        """Attach to a root and start rendering its complete tree."""

        with self._lock:
            self._root = root
            self._revision += 1
            self._stop_ticker.set()
            self._stop_ticker = Event()
            ticker = self._stop_ticker
            root.signals.changed.connect(self._changed)
        self._live.start()
        self._paint()
        # The ticker is never joined: waiting for it while a finishing task
        # holds the task-tree lock would deadlock against a tick that is
        # reading the tree. A straggling tick after the display stops paints
        # nothing because the frame fingerprint is unchanged.
        Thread(
            target=self._tick,
            args=(ticker,),
            name="task-frame-ticker",
            daemon=True,
        ).start()

    def _tick(self, stop: Event) -> None:
        while not stop.wait(self._tick_seconds):
            self._paint()

    def announce(self, message: str) -> None:
        """Pin one urgent line above the tree until the display stops.

        Safe to call from a signal handler: it only marks state, and the next
        tick paints.
        """

        with self._lock:
            self._banner = message
            self._revision += 1

    def _paint(self) -> None:
        fingerprint = self._fingerprint()
        if fingerprint is None:
            return
        with self._paint_lock:
            if fingerprint == self._painted:
                return
        with self._lock:
            root = self._root
            banner = self._banner
        if root is None:
            return
        frame = render_frame(
            root.snapshot(),
            self._console.width,
            self._console.size.height,
            self._clock,
        )
        if banner is not None:
            announcement = Text(no_wrap=True, overflow="crop", end="")
            announcement.append(banner, style="bold yellow")
            announcement.append("\n")
            announcement.append_text(frame)
            frame = announcement
        with self._paint_lock:
            if fingerprint == self._painted:
                return
            self._painted = fingerprint
            self._live.update(frame, refresh=True)

    def _changed(self, change: TaskChange) -> None:
        with self._lock:
            if self._root is None:
                return
            self._revision += 1
            finished = (
                change.kind is TaskChangeKind.FINISHED
                and change.task.path == self._root.path
            )
            if finished:
                self._stop_ticker.set()
        if finished:
            self._paint()
            self._live.stop()

    def _fingerprint(self) -> object:
        with self._lock:
            if self._root is None:
                return None
            revision = self._revision
        return (revision, int(self._clock() / _SPINNER_INTERVAL_SECONDS))


@dataclass(frozen=True)
class TaskRow:
    """One visible line of a frame, with any folded-descendant summary."""

    snapshot: TaskSnapshot
    guide: str
    strip: tuple[tuple[str, str], ...]
    promoted: TaskActivity | None


def render_frame(
    snapshot: TaskSnapshot,
    width: int,
    height: int,
    clock: Callable[[], float],
) -> Text:
    """Render the densest layout of the task tree which fits the terminal."""

    now = clock()
    budget = max(_MINIMUM_ROW_BUDGET, height - 1)
    rows, hidden = frame_rows(snapshot, budget)
    frame = Text(no_wrap=True, overflow="crop", end="")
    for index, row in enumerate(rows):
        if index:
            frame.append("\n")
        frame.append_text(_row_text(row, width, now))
    if hidden:
        frame.append("\n")
        frame.append(f"… {hidden} more", style="dim")
    return frame


def frame_rows(
    snapshot: TaskSnapshot,
    budget: int,
) -> tuple[tuple[TaskRow, ...], int]:
    """Choose the deepest global fold level whose rows fit the budget.

    Levels hide everything below one depth and summarise the hidden subtree
    on its deepest visible ancestor. When even the shallowest level exceeds
    the budget, the tail rows are dropped and their count is returned.
    """

    for cutoff in range(_tree_depth(snapshot), 0, -1):
        rows = tuple(_rows(snapshot, cutoff, 0, ()))
        if len(rows) <= budget:
            return rows, 0

    rows = tuple(_rows(snapshot, 1, 0, ()))
    if len(rows) <= budget:
        return rows, 0
    return rows[: budget - 1], len(rows) - (budget - 1)


def _tree_depth(snapshot: TaskSnapshot) -> int:
    if _folded(snapshot):
        return 1
    return 1 + max(
        (_tree_depth(child) for child in snapshot.children),
        default=0,
    )


def _rows(
    snapshot: TaskSnapshot,
    cutoff: int,
    depth: int,
    continuing: tuple[bool, ...],
) -> Iterator[TaskRow]:
    children = () if _folded(snapshot) else snapshot.children
    hidden = bool(children) and depth + 1 > cutoff
    yield TaskRow(
        snapshot=snapshot,
        guide=_guide(depth, continuing),
        strip=_strip(snapshot) if hidden else (),
        promoted=_latest_activity(snapshot) if hidden else None,
    )
    if hidden:
        return
    for index, child in enumerate(children):
        last = index == len(children) - 1
        yield from _rows(
            child,
            cutoff,
            depth + 1,
            (*continuing, not last),
        )


def _folded(snapshot: TaskSnapshot) -> bool:
    return snapshot.outcome in (
        TaskOutcome.COMPLETED,
        TaskOutcome.PASSED,
        TaskOutcome.SKIPPED,
    ) and all(_folded(child) for child in snapshot.children)


def _guide(depth: int, continuing: tuple[bool, ...]) -> str:
    if depth == 0:
        return ""
    trunk = "".join("│   " if ancestor else "    " for ancestor in continuing[:-1])
    return trunk + ("├── " if continuing[-1] else "└── ")


_STRIP_GLYPHS = {
    TaskOutcome.COMPLETED: ("●", "blue"),
    TaskOutcome.PASSED: ("✓", "green"),
    TaskOutcome.FAILED: ("✗", "red"),
    TaskOutcome.INVALID: ("!", "yellow"),
    TaskOutcome.CANCELLED: ("■", "yellow"),
    TaskOutcome.SKIPPED: ("–", "dim"),
}


def _strip(snapshot: TaskSnapshot) -> tuple[tuple[str, str], ...]:
    """Summarise immediate children as one glyph each, in allocation order."""

    children = {child.path[-1]: child for child in snapshot.children}
    glyphs: list[tuple[str, str]] = []
    for allocation in snapshot.child_progress.children:
        child = children.get(allocation.name)
        if child is None:
            glyphs.append(("●", "blue") if allocation.completed else ("·", "dim"))
            continue
        if child.outcome is None:
            glyphs.append(("◐", "blue"))
            continue
        glyphs.append(_STRIP_GLYPHS[child.outcome])
    if len(glyphs) > _MAXIMUM_STRIP_GLYPHS:
        surplus = len(glyphs) - (_MAXIMUM_STRIP_GLYPHS - 1)
        glyphs = [*glyphs[: _MAXIMUM_STRIP_GLYPHS - 1], (f"+{surplus}", "dim")]
    return tuple(glyphs)


def _latest_activity(snapshot: TaskSnapshot) -> TaskActivity | None:
    activities = [snapshot.activity] if snapshot.activity is not None else []
    activities.extend(
        activity
        for child in snapshot.children
        if (activity := _latest_activity(child)) is not None
    )
    return max(
        activities,
        key=lambda activity: (activity.observed_at, activity.sequence),
        default=None,
    )


def _row_text(row: TaskRow, width: int, now: float) -> Text:
    snapshot = row.snapshot
    text = Text(no_wrap=True, overflow="crop", end="")

    marker, marker_style = _status(snapshot, now)
    text.append(marker.ljust(_STATUS_WIDTH), style=marker_style)
    text.append(" ")

    description_width = max(_MINIMUM_DESCRIPTION_WIDTH, width - _FIXED_ROW_WIDTH)
    _append_description(text, row, description_width)
    text.append(" ")

    _append_bar(text, snapshot, now)
    text.append(" ")

    text.append(progress_count(snapshot).rjust(_COUNT_WIDTH))
    text.append(" ")
    text.append(
        format_elapsed(snapshot, now).rjust(_ELAPSED_WIDTH),
        style="dim",
    )
    text.append(" ")
    text.append(
        _clip(_detail(row, now), _DETAIL_WIDTH).rjust(_DETAIL_WIDTH), style="dim"
    )
    return text


def _append_description(text: Text, row: TaskRow, width: int) -> None:
    strip_width = sum(len(glyph) for glyph, _ in row.strip)
    if row.strip:
        strip_width += 1
    name_width = max(1, width - strip_width)
    name = _clip(row.guide + row.snapshot.description, name_width)

    text.append(name[: len(row.guide)], style="dim")
    text.append(name[len(row.guide) :])
    padding = name_width - len(name)
    if row.strip:
        text.append(" ")
        for glyph, style in row.strip:
            text.append(glyph, style=style)
    text.append(" " * padding)


def _status(snapshot: TaskSnapshot, now: float) -> tuple[str, str]:
    if snapshot.outcome is None:
        return _spinner_frame(now), "blue"
    statuses = {
        TaskOutcome.COMPLETED: ("●", "blue"),
        TaskOutcome.PASSED: ("✓", "green"),
        TaskOutcome.FAILED: ("✗", "red"),
        TaskOutcome.INVALID: ("!", "yellow"),
        TaskOutcome.CANCELLED: ("■", "yellow"),
        TaskOutcome.SKIPPED: ("–", "dim"),
    }
    return statuses[snapshot.outcome]


def _spinner_frame(now: float) -> str:
    index = int(now / _SPINNER_INTERVAL_SECONDS) % len(_SPINNER_FRAMES)
    return _SPINNER_FRAMES[index]


def _append_bar(text: Text, snapshot: TaskSnapshot, now: float) -> None:
    _, total = displayed_progress(snapshot)
    if total is None:
        _append_pulse(text, now)
        return
    if total == 0:
        text.append(" " * _BAR_WIDTH)
        return
    fraction = task_completion_fraction(snapshot) or 0.0
    filled = min(_BAR_WIDTH, int(fraction * _BAR_WIDTH))
    text.append("━" * filled, style="blue")
    text.append("─" * (_BAR_WIDTH - filled), style="dim")


def _append_pulse(text: Text, now: float) -> None:
    head = int(now / _SPINNER_INTERVAL_SECONDS) % _BAR_WIDTH
    cells = ["─"] * _BAR_WIDTH
    for offset in range(3):
        cells[(head + offset) % _BAR_WIDTH] = "━"
    for cell in cells:
        text.append(cell, style="blue" if cell == "━" else "dim")


def _detail(row: TaskRow, now: float) -> str:
    snapshot = row.snapshot
    if snapshot.outcome is not None:
        return snapshot.detail
    activity = row.promoted or snapshot.activity
    if activity is not None:
        return activity_detail(activity, now)
    return snapshot.detail


def _clip(value: str, width: int) -> str:
    if len(value) <= width:
        return value
    return value[: width - 1] + "…"


def displayed_progress(snapshot: TaskSnapshot) -> tuple[int, int | None]:
    """Return the task's explicit, stable progress measurement."""

    return snapshot.completed, snapshot.total


def progress_count(snapshot: TaskSnapshot) -> str:
    """Format immediate-child completion without inventing an unknown total."""

    completed, total = displayed_progress(snapshot)
    if total is None:
        return f"{completed} complete"
    return f"{completed}/{total}"


def task_completion_fraction(snapshot: TaskSnapshot) -> float | None:
    """Return weighted recursive completion from explicit child allocations."""

    plan = snapshot.child_progress
    if plan.kind is TaskChildrenKind.UNBOUNDED and not plan.sealed:
        return None

    denominator = (
        float(plan.maximum)
        if plan.kind is TaskChildrenKind.BOUNDED
        and not plan.sealed
        and plan.maximum is not None
        else sum(child.weight for child in plan.children)
    )
    if denominator == 0:
        return 1.0 if snapshot.outcome is not None else 0.0

    child_tasks = {child.path[-1]: child for child in snapshot.children}
    completed = 0.0
    for allocation in plan.children:
        if allocation.completed:
            completed += allocation.weight
            continue
        child = child_tasks.get(allocation.name)
        if child is None:
            continue
        fraction = task_completion_fraction(child)
        if fraction is not None:
            completed += allocation.weight * fraction

    return min(1.0, completed / denominator)


def format_elapsed(snapshot: TaskSnapshot, now: float) -> str:
    """Format elapsed monotonic time for a live or completed task."""

    end = snapshot.finished_at if snapshot.finished_at is not None else now
    elapsed = max(0, int(end - snapshot.started_at))
    minutes, seconds = divmod(elapsed, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02}:{seconds:02}"


def task_detail(snapshot: TaskSnapshot, clock: Callable[[], float]) -> str:
    """Render the detail chosen by the task owner or its own live activity."""

    if snapshot.outcome is not None:
        return snapshot.detail

    if snapshot.activity is not None:
        return activity_detail(snapshot.activity, clock())

    return snapshot.detail


def activity_detail(activity: TaskActivity, now: float) -> str:
    """Describe one live operation with its age and heartbeat recency."""

    elapsed = max(activity.elapsed_seconds, int(now - activity.started_at))
    heartbeat_age = max(0, int(now - activity.observed_at))
    suffix = (
        f" · heartbeat {format_recency(heartbeat_age)}" if activity.heartbeat else ""
    )
    return f"{activity.description} · active {format_duration(elapsed)}{suffix}"


def format_duration(seconds: int) -> str:
    """Format an operation duration without implying a deadline."""

    minutes, seconds = divmod(max(0, seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}:{minutes:02}:{seconds:02}"
    return f"{minutes}:{seconds:02}"


def format_recency(seconds: int) -> str:
    """Describe how stale an observation is without imposing a timeout."""

    if seconds == 0:
        return "now"
    return f"{format_duration(seconds)} ago"
