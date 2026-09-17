from __future__ import annotations

import re
from collections.abc import Iterable, Sequence

_SCP = re.compile(r"^(?:[^@/]+@)?github\.com:(?P<owner>[^/]+)/")
_URL = re.compile(
    r"^(?:ssh|https?|git)://(?:[^@/]+@)?github\.com(?::\d+)?/(?P<owner>[^/]+)/"
)


def remote_owner(url: str) -> str | None:
    """The GitHub account a remote URL points at, or None for any other host."""
    for pattern in (_SCP, _URL):
        match = pattern.match(url.strip())
        if match is not None:
            return match.group("owner").lower()

    return None


def repository_is_owned(urls: Iterable[str], owners: Sequence[str]) -> bool:
    """Whether every remote points at one of the configured owner accounts.

    A repository with no remotes counts as owned: it exists only on this
    machine, so there is no other account for it to belong to.
    """
    configured = {owner.lower() for owner in owners}

    return all(remote_owner(url) in configured for url in urls)
