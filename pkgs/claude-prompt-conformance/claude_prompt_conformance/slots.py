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

    Every candidate, judge, and improver invocation holds one slot for as long
    as its process runs. Cheap phases such as repository preparation and
    workspace inspection hold none, so the limit describes model concurrency
    rather than task concurrency.
    """

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise WorkerCountError(capacity, 1)
        self._capacity = capacity
        self._semaphore = BoundedSemaphore(capacity)

    @property
    def capacity(self) -> int:
        """Return the number of agent processes this run may keep active."""

        return self._capacity

    @contextmanager
    def hold(self) -> Iterator[None]:
        """Hold one slot for the duration of a single agent process."""

        self._semaphore.acquire()
        try:
            yield
        finally:
            self._semaphore.release()
