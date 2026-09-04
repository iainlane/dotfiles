"""Lossless storage model for Claude's shared host credential document."""

from dataclasses import dataclass, field
from typing import Any

import msgspec

from .errors import ConformanceError
from .protocols.claude import ClaudeCredentialInput, ClaudeOAuth


@dataclass(eq=True)
class ClaudeCredentialFormatError(ConformanceError):
    cause: Exception

    def __str__(self) -> str:
        return f"the Claude credential has an invalid format: {self.cause}"


@dataclass(eq=True)
class ClaudeTokenMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the Claude credential has no access token"


@dataclass(eq=True)
class ClaudeRefreshTokenMissingError(ConformanceError):
    def __str__(self) -> str:
        return "the Claude credential has no refresh token"


@dataclass(frozen=True)
class ClaudeCredential:
    """A typed OAuth view paired with the complete opaque storage document."""

    document: dict[str, Any] = field(repr=False)
    oauth: ClaudeOAuth = field(repr=False)

    @classmethod
    def decode(cls, value: bytes) -> "ClaudeCredential":
        """Decode the known OAuth fields without discarding unrelated state."""

        try:
            document = msgspec.json.decode(value, type=dict[str, Any])
            known = msgspec.convert(document, type=ClaudeCredentialInput)
        except (msgspec.DecodeError, msgspec.ValidationError) as error:
            raise ClaudeCredentialFormatError(error) from error
        validate_oauth(known.oauth)

        return cls(document, known.oauth)

    def with_oauth(self, oauth: ClaudeOAuth) -> "ClaudeCredential":
        """Replace renewable OAuth values while preserving every opaque field."""

        oauth_document = dict(self.document.get("claudeAiOauth", {}))
        oauth_document.update(
            {
                "accessToken": oauth.access_token,
                "refreshToken": oauth.refresh_token,
                "expiresAt": oauth.expires_at,
                "scopes": list(oauth.scopes),
            }
        )
        if oauth.refresh_token_expires_at is not None:
            oauth_document["refreshTokenExpiresAt"] = oauth.refresh_token_expires_at
        if oauth.client_id is not None:
            oauth_document["clientId"] = oauth.client_id
        if oauth.subscription_type is not None:
            oauth_document["subscriptionType"] = oauth.subscription_type
        if oauth.rate_limit_tier is not None:
            oauth_document["rateLimitTier"] = oauth.rate_limit_tier
        return ClaudeCredential(
            self.document | {"claudeAiOauth": oauth_document},
            oauth,
        )

    def encode(self) -> bytes:
        """Encode the losslessly retained credential document."""

        return msgspec.json.encode(self.document)


def validate_oauth(oauth: ClaudeOAuth) -> None:
    """Reject a decoded or refreshed credential which cannot authenticate."""

    if not oauth.access_token:
        raise ClaudeTokenMissingError
    if not oauth.refresh_token:
        raise ClaudeRefreshTokenMissingError
