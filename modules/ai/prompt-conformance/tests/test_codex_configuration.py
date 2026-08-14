import errno
from pathlib import Path

from claude_prompt_conformance.models import CodexHostConfiguration
from claude_prompt_conformance.platforms.codex import (
    CodexEnforcedConfigurationPresentError,
    CodexHostConfigurationReadError,
    CodexHostConfigurationSyntaxError,
    CodexHostMcpServersTypeError,
    load_codex_host_configuration,
)


def test_codex_host_configuration_collects_system_mcp_server_names(
    tmp_path: Path,
) -> None:
    missing = tmp_path / "missing.toml"
    first = tmp_path / "first.toml"
    first.write_text(
        """
[mcp_servers.docs]
url = "https://docs.example.invalid/mcp"

[mcp_servers.local]
command = "/nix/store/example/bin/server"
"""
    )
    second = tmp_path / "second.toml"
    second.write_text(
        """
[mcp_servers.docs]
enabled = false

[mcp_servers.review]
url = "https://review.example.invalid/mcp"
"""
    )

    actual = load_codex_host_configuration(
        (missing, first, second), enforced_sources=()
    )

    assert actual == CodexHostConfiguration(mcp_servers=("docs", "local", "review"))


def test_codex_host_configuration_rejects_invalid_toml(tmp_path: Path) -> None:
    source = tmp_path / "system.toml"
    source.write_text("invalid = [")

    try:
        load_codex_host_configuration((source,), enforced_sources=())
    except CodexHostConfigurationSyntaxError as error:
        actual = error
    else:
        raise AssertionError("invalid TOML was accepted")

    assert actual == CodexHostConfigurationSyntaxError(source)


def test_codex_host_configuration_requires_an_mcp_server_table(
    tmp_path: Path,
) -> None:
    source = tmp_path / "managed.toml"
    source.write_text("mcp_servers = 1")

    try:
        load_codex_host_configuration((source,), enforced_sources=())
    except CodexHostMcpServersTypeError as error:
        actual = error
    else:
        raise AssertionError("a scalar mcp_servers value was accepted")

    assert actual == CodexHostMcpServersTypeError(source, int)


def test_codex_host_configuration_reports_unreadable_system_settings(
    tmp_path: Path,
) -> None:
    source = tmp_path / "managed.toml"
    source.mkdir()

    try:
        load_codex_host_configuration((source,), enforced_sources=())
    except CodexHostConfigurationReadError as error:
        actual = error
    else:
        raise AssertionError("an unreadable system configuration was accepted")

    assert actual == CodexHostConfigurationReadError(source, errno.EISDIR)


def test_codex_host_configuration_rejects_legacy_enforced_settings(
    tmp_path: Path,
) -> None:
    source = tmp_path / "managed_config.toml"
    source.write_text(
        """
[mcp_servers.docs]
url = "https://docs.example.invalid/mcp"
"""
    )

    try:
        load_codex_host_configuration((), enforced_sources=(source,))
    except CodexEnforcedConfigurationPresentError as error:
        actual = error
    else:
        raise AssertionError("legacy Codex enforcement was accepted")

    assert actual == CodexEnforcedConfigurationPresentError(source)
