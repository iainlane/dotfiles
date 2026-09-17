"""Run-wide bounding of concurrently active model-agent processes."""

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from threading import BoundedSemaphore

from .errors import ConformanceError


@dataclass(eq=True)
class WorkerCountError(ConformanceError):
    actual: int
    minimum: int

    def __str__(self) -> str:
        return f"worker count {self.actual} is below {self.minimum}"


class SlotPool:
    """Limit how many agent processes one run keeps active at the same time.

    Only invocations that run a model take a slot. Adding one around
    repository preparation or evidence capture would change what `--jobs`
    counts.
    """

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise WorkerCountError(capacity, 1)
        self._capacity = capacity
        self._semaphore = BoundedSemaphore(capacity)

    @property
    def capacity(self) -> int:
        return self._capacity

    @contextmanager
    def hold(self) -> Iterator[None]:
        self._semaphore.acquire()
        try:
            yield
        finally:
            self._semaphore.release()
