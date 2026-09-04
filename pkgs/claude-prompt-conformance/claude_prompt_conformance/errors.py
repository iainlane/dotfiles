"""Typed failures at the conformance suite's external boundaries."""


class ConformanceError(RuntimeError):
    """Base class used only to terminate one fixture without a traceback."""


class CodexRuntimeError(ConformanceError):
    """Base class for independent judge or improver infrastructure failures."""


class ProcessExecutionError(ConformanceError):
    """Base class for failures in the process supervisor itself."""


class RetainedStateError(ConformanceError):
    """Base class for failures of the suite's own retained fixture state."""


class TaskInvariantError(RuntimeError):
    """Base class for invalid progress task construction and transitions."""
