"""Pinned Claude secure-storage location and namespace selection."""

import unicodedata
from collections.abc import Mapping
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

from .errors import ConformanceError


@dataclass(eq=True)
class ClaudeCustomOAuthUrlUnsupportedError(ConformanceError):
    endpoint: str

    def __str__(self) -> str:
        return f"Claude custom OAuth endpoint is not approved: {self.endpoint}"


_APPROVED_CUSTOM_OAUTH_URLS = frozenset(
    {
        "https://beacon.claude-ai.staging.ant.dev",
        "https://claude.fedstart.com",
        "https://claude-staging.fedstart.com",
    }
)


@dataclass(frozen=True)
class ClaudeSecureStorage:
    """Resolved credential directory and Keychain service namespace."""

    directory: Path
    keychain_service: str

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str],
        home: Path,
    ) -> "ClaudeSecureStorage":
        """Match secure-storage selection in the pinned Claude client."""

        default_directory = home / ".claude"
        secure_directory = environment.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        if secure_directory is not None:
            selected = secure_directory if secure_directory else str(default_directory)
            hash_namespace = bool(secure_directory)
        else:
            configured_directory = environment.get("CLAUDE_CONFIG_DIR")
            selected = (
                configured_directory
                if configured_directory is not None
                else str(default_directory)
            )
            hash_namespace = bool(configured_directory)

        normalized = unicodedata.normalize("NFC", selected)
        namespace_suffix = ""
        if hash_namespace:
            namespace_suffix = f"-{sha256(normalized.encode()).hexdigest()[:8]}"

        oauth_suffix = _oauth_file_suffix(environment)
        return cls(
            Path(normalized),
            f"Claude Code{oauth_suffix}-credentials{namespace_suffix}",
        )


def _oauth_file_suffix(environment: Mapping[str, str]) -> str:
    custom_url = environment.get("CLAUDE_CODE_CUSTOM_OAUTH_URL")
    if not custom_url:
        return ""

    normalized = custom_url.removesuffix("/")
    if normalized not in _APPROVED_CUSTOM_OAUTH_URLS:
        raise ClaudeCustomOAuthUrlUnsupportedError(normalized)
    return "-custom-oauth"
