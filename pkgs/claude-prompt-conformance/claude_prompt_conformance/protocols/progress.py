"""Streaming progress records shared with non-interactive frontends."""

import msgspec

from ..progress import TaskChangeKind, TaskSnapshot


class TaskObserved(
    msgspec.Struct,
    frozen=True,
    tag="TaskObserved",
    tag_field="event",
):
    change: TaskChangeKind
    task: TaskSnapshot
