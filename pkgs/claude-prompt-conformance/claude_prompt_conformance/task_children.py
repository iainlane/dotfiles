"""Declarative child allocation for hierarchical task progress."""

import math
from dataclasses import dataclass
from enum import StrEnum

from .errors import TaskInvariantError


@dataclass(eq=True)
class InvalidTaskChildWeightError(TaskInvariantError):
    child: str
    weight: float

    def __str__(self) -> str:
        return f"progress child {self.child!r} has invalid weight {self.weight!r}"


@dataclass(eq=True)
class DuplicateTaskChildAllocationError(TaskInvariantError):
    child: str

    def __str__(self) -> str:
        return f"progress child {self.child!r} is allocated more than once"


@dataclass(eq=True)
class NegativeBoundedTaskChildrenMaximumError(TaskInvariantError):
    maximum: int

    def __str__(self) -> str:
        return f"bounded progress children have negative maximum {self.maximum}"


@dataclass(eq=True)
class BoundedTaskChildrenOverflowError(TaskInvariantError):
    maximum: int
    attempted: int

    def __str__(self) -> str:
        return (
            f"bounded progress children allow {self.maximum}, "
            f"but child {self.attempted} was registered"
        )


@dataclass(eq=True)
class UndeclaredTaskChildError(TaskInvariantError):
    child: str

    def __str__(self) -> str:
        return f"fixed progress child {self.child!r} was not declared"


@dataclass(eq=True)
class UnknownTaskChildError(TaskInvariantError):
    child: str

    def __str__(self) -> str:
        return f"progress child {self.child!r} does not exist"


@dataclass(eq=True)
class TaskChildAlreadyRegisteredError(TaskInvariantError):
    child: str

    def __str__(self) -> str:
        return f"progress child {self.child!r} is already registered"


@dataclass(eq=True)
class TaskChildAlreadyCompletedError(TaskInvariantError):
    child: str

    def __str__(self) -> str:
        return f"progress child {self.child!r} is already complete"


@dataclass(eq=True)
class SealedTaskChildrenMutationError(TaskInvariantError):
    def __str__(self) -> str:
        return "sealed progress children cannot be changed"


class TaskChildrenKind(StrEnum):
    """How completely a task knows its children before it begins."""

    FIXED = "fixed"
    BOUNDED = "bounded"
    UNBOUNDED = "unbounded"


@dataclass(frozen=True)
class ChildAllocation:
    """Reserve a relative share of a fixed parent's progress for one child."""

    name: str
    weight: float = 1.0

    def __post_init__(self) -> None:
        if not math.isfinite(self.weight) or self.weight <= 0:
            raise InvalidTaskChildWeightError(self.name, self.weight)


@dataclass(frozen=True)
class FixedTaskChildren:
    """Declare every child and its progress weight before a task begins."""

    allocations: tuple[ChildAllocation, ...] = ()

    def __post_init__(self) -> None:
        names = tuple(allocation.name for allocation in self.allocations)
        duplicates = tuple(
            name for index, name in enumerate(names) if name in names[:index]
        )
        if duplicates:
            raise DuplicateTaskChildAllocationError(duplicates[0])

    @classmethod
    def equal(cls, *names: str) -> "FixedTaskChildren":
        """Allocate equal progress regions to a fixed ordered child list."""

        return cls(tuple(ChildAllocation(name) for name in names))


@dataclass(frozen=True)
class BoundedTaskChildren:
    """Allow children to be discovered up to a known pessimistic maximum."""

    maximum: int

    def __post_init__(self) -> None:
        if self.maximum < 0:
            raise NegativeBoundedTaskChildrenMaximumError(self.maximum)


@dataclass(frozen=True)
class UnboundedTaskChildren:
    """Allow an unknown number of children until the task seals its list."""


TaskChildren = FixedTaskChildren | BoundedTaskChildren | UnboundedTaskChildren


@dataclass(frozen=True)
class TaskChildSnapshot:
    """Describe one allocated child region without frontend-specific state."""

    name: str
    weight: float
    registered: bool
    completed: bool


@dataclass(frozen=True)
class TaskChildrenSnapshot:
    """An immutable view of a task's child-discovery and allocation state."""

    kind: TaskChildrenKind
    sealed: bool
    maximum: int | None
    children: tuple[TaskChildSnapshot, ...]

    @property
    def completed(self) -> int:
        """Return the number of terminal immediate child regions."""

        return sum(child.completed for child in self.children)

    @property
    def total(self) -> int | None:
        """Return the current count denominator, if it is knowable."""

        if self.kind is TaskChildrenKind.FIXED or self.sealed:
            return len(self.children)
        return self.maximum


@dataclass
class _TaskChild:
    name: str
    weight: float
    registered: bool = False
    completed: bool = False


class TaskChildAllocations:
    """Own mutable child-discovery state for one task run."""

    def __init__(self, specification: TaskChildren) -> None:
        self._kind = _kind(specification)
        self._sealed = isinstance(specification, FixedTaskChildren)
        self._maximum = (
            specification.maximum
            if isinstance(specification, BoundedTaskChildren)
            else None
        )
        self._children = (
            [
                _TaskChild(allocation.name, allocation.weight)
                for allocation in specification.allocations
            ]
            if isinstance(specification, FixedTaskChildren)
            else []
        )

    def register(self, name: str) -> None:
        """Claim a declared region or append one dynamically discovered child."""

        child = self._find(name)
        if child is not None:
            if child.registered:
                raise TaskChildAlreadyRegisteredError(name)
            if child.completed:
                raise TaskChildAlreadyCompletedError(name)
            child.registered = True
            return

        if self._sealed:
            raise UndeclaredTaskChildError(name)
        self._append(name, registered=True)

    def complete(self, name: str, *, direct: bool = False) -> None:
        """Mark a child region terminal after direct work or a child task finishes."""

        child = self._find(name)
        if child is None:
            if self._sealed:
                raise UnknownTaskChildError(name)
            if direct:
                self._append(name, registered=False, completed=True)
                return
            self.register(name)
            child = self._required(name)
        if child.completed:
            raise TaskChildAlreadyCompletedError(name)
        if direct and child.registered:
            raise TaskChildAlreadyRegisteredError(name)
        if not direct and not child.registered:
            raise UndeclaredTaskChildError(name)
        child.completed = True

    def seal(self) -> None:
        """Declare that an open task will register no additional children."""

        if self._sealed:
            raise SealedTaskChildrenMutationError
        self._sealed = True

    def snapshot(self) -> TaskChildrenSnapshot:
        """Return immutable child state in declaration or discovery order."""

        return TaskChildrenSnapshot(
            kind=self._kind,
            sealed=self._sealed,
            maximum=self._maximum,
            children=tuple(
                TaskChildSnapshot(
                    name=child.name,
                    weight=child.weight,
                    registered=child.registered,
                    completed=child.completed,
                )
                for child in self._children
            ),
        )

    @property
    def sealed(self) -> bool:
        """Return whether additional children are forbidden."""

        return self._sealed

    def _find(self, name: str) -> _TaskChild | None:
        return next((child for child in self._children if child.name == name), None)

    def _required(self, name: str) -> _TaskChild:
        child = self._find(name)
        if child is None:
            raise UnknownTaskChildError(name)
        return child

    def _append(
        self,
        name: str,
        *,
        registered: bool,
        completed: bool = False,
    ) -> None:
        if self._maximum is not None and len(self._children) >= self._maximum:
            raise BoundedTaskChildrenOverflowError(
                self._maximum, len(self._children) + 1
            )
        self._children.append(
            _TaskChild(
                name,
                1.0,
                registered=registered,
                completed=completed,
            )
        )


def _kind(specification: TaskChildren) -> TaskChildrenKind:
    if isinstance(specification, FixedTaskChildren):
        return TaskChildrenKind.FIXED
    if isinstance(specification, BoundedTaskChildren):
        return TaskChildrenKind.BOUNDED
    return TaskChildrenKind.UNBOUNDED
