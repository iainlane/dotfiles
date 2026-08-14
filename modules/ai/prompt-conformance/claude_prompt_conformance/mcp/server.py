"""Start an instance-scoped MCP server for one model role."""

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from ..errors import ConformanceError
from ..protocols.mcp import EvaluatorDescriptor, ImproverDescriptor, McpDescriptor
from .configuration import load_configuration
from .evaluator import EvaluatorEvidence, create_evaluator_server
from .improver import ImproverEvidence, create_improver_server


def create_server(configuration: McpDescriptor) -> FastMCP[None]:
    """Create the smallest read-only tool set required for one model role."""

    match configuration:
        case EvaluatorDescriptor():
            return create_evaluator_server(EvaluatorEvidence(configuration))
        case ImproverDescriptor():
            return create_improver_server(ImproverEvidence(configuration))


def parser() -> argparse.ArgumentParser:
    """Define the private stdio server's positional configuration interface."""

    result = argparse.ArgumentParser(description="Serve one conformance evidence set")
    result.add_argument("configuration", type=Path, metavar="CONFIGURATION")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    """Run one role-specific MCP server over standard input and output."""

    try:
        return _main(argv)
    except KeyboardInterrupt:
        return 130


def _main(argv: Sequence[str] | None = None) -> int:
    """Parse the instance descriptor and serve it until the client disconnects."""

    arguments = parser().parse_args(argv)
    try:
        configuration = load_configuration(arguments.configuration)
        create_server(configuration).run()
    except ConformanceError as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
