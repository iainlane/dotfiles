"""Unconfined process execution for hermetic adapter tests."""

from ..models import ProcessInvocation, ProcessResult
from ..ports import ProcessSession
from ..process import ProcessSupervisor


class DirectProcessRunner:
    """Execute an invocation directly inside an already-hermetic test process."""

    def __init__(self, processes: ProcessSupervisor) -> None:
        self._processes = processes

    def run(self, invocation: ProcessInvocation) -> ProcessResult:
        return self._processes.run(invocation, invocation.command)

    def run_interactive(
        self,
        invocation: ProcessInvocation,
        session: ProcessSession,
    ) -> ProcessResult:
        """Run a bidirectional protocol without adding an isolation wrapper."""

        return self._processes.run_interactive(
            invocation,
            invocation.command,
            session,
        )
