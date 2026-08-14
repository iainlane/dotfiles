"""Typed persistence for instance-specific MCP capability descriptors."""

from dataclasses import dataclass
from pathlib import Path

import msgspec

from ..errors import CodexRuntimeError, ConformanceError
from ..protocols.mcp import McpDescriptor
from ..storage import RetainedPathUnsafeError, atomic_write


@dataclass(eq=True)
class CodexMcpConfigurationWriteError(CodexRuntimeError):
    destination: Path
    cause: OSError | RetainedPathUnsafeError

    def __str__(self) -> str:
        return (
            f"could not write Codex MCP configuration {self.destination}: {self.cause}"
        )


@dataclass(eq=True)
class McpConfigurationFormatError(ConformanceError):
    source: Path
    cause: Exception

    def __str__(self) -> str:
        return f"MCP instance configuration {self.source} is invalid: {self.cause}"


def load_configuration(path: Path) -> McpDescriptor:
    """Decode one role-tagged MCP instance configuration."""

    try:
        return msgspec.json.decode(path.read_bytes(), type=McpDescriptor)
    except (OSError, msgspec.DecodeError, msgspec.ValidationError) as error:
        raise McpConfigurationFormatError(path, error) from error


def write_configuration(
    root: Path,
    path: Path,
    configuration: McpDescriptor,
) -> Path:
    """Persist a validated instance descriptor for a spawned MCP process."""

    try:
        atomic_write(root, path, msgspec.json.encode(configuration))
    except (OSError, RetainedPathUnsafeError) as error:
        raise CodexMcpConfigurationWriteError(path, error) from error
    return path
