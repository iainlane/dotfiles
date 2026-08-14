"""Host-managed Codex configuration discovery."""

import tomllib
from dataclasses import dataclass
from pathlib import Path

from ..errors import CodexRuntimeError
from ..models import CodexHostConfiguration


@dataclass(eq=True)
class CodexHostConfigurationReadError(CodexRuntimeError):
    source: Path
    errno: int | None

    def __str__(self) -> str:
        return f"could not read host Codex configuration {self.source} (errno {self.errno})"


@dataclass(eq=True)
class CodexHostConfigurationSyntaxError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return f"host Codex configuration {self.source} contains invalid TOML"


@dataclass(eq=True)
class CodexHostMcpServersTypeError(CodexRuntimeError):
    source: Path
    actual_type: type[object]

    def __str__(self) -> str:
        return (
            f"host Codex configuration {self.source} has mcp_servers of type "
            f"{self.actual_type.__name__}"
        )


@dataclass(eq=True)
class CodexEnforcedConfigurationPresentError(CodexRuntimeError):
    source: Path

    def __str__(self) -> str:
        return (
            f"legacy Codex enforcement configuration {self.source} overrides "
            "isolated judge settings; activate this repository's system "
            "configuration before running the suite"
        )


CODEX_HOST_CONFIGURATION_SOURCES = (Path("/etc/codex/config.toml"),)
CODEX_ENFORCED_CONFIGURATION_SOURCES = (Path("/etc/codex/managed_config.toml"),)


def load_codex_host_configuration(
    sources: tuple[Path, ...] = CODEX_HOST_CONFIGURATION_SOURCES,
    enforced_sources: tuple[Path, ...] = CODEX_ENFORCED_CONFIGURATION_SOURCES,
) -> CodexHostConfiguration:
    """Collect MCP names which an isolated instance must disable."""

    for source in enforced_sources:
        configuration = _load_configuration(source)
        if configuration:
            raise CodexEnforcedConfigurationPresentError(source)

    names: set[str] = set()
    for source in sources:
        configuration = _load_configuration(source)
        if configuration is None:
            continue

        servers = configuration.get("mcp_servers", {})
        if not isinstance(servers, dict):
            raise CodexHostMcpServersTypeError(source, type(servers))
        names.update(servers.keys())

    return CodexHostConfiguration(mcp_servers=tuple(sorted(names)))


def _load_configuration(source: Path) -> dict[str, object] | None:
    """Read one optional host configuration document."""

    try:
        contents = source.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise CodexHostConfigurationReadError(source, error.errno) from error

    try:
        return tomllib.loads(contents.decode())
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise CodexHostConfigurationSyntaxError(source) from error
