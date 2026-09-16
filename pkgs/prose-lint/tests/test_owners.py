import pytest

from prose_lint.owners import remote_owner, repository_is_owned

OWNERS = ("iainlane", "underwhelmingperformance")


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("git@github.com:iainlane/dotfiles.git", "iainlane"),
        ("git@github.com:iainlane/dotfiles", "iainlane"),
        ("ssh://git@github.com/iainlane/dotfiles.git", "iainlane"),
        ("ssh://git@github.com:22/iainlane/dotfiles.git", "iainlane"),
        ("https://github.com/IainLane/dotfiles.git", "iainlane"),
        ("https://iain@github.com/iainlane/dotfiles", "iainlane"),
        ("git://github.com/iainlane/dotfiles.git", "iainlane"),
        ("https://gitlab.com/iainlane/dotfiles.git", None),
        ("/srv/mirrors/dotfiles.git", None),
        ("", None),
    ],
)
def test_remote_owner_reads_the_owner_from_every_github_url_form(
    url: str, expected: str | None
) -> None:
    assert remote_owner(url) == expected


@pytest.mark.parametrize(
    ("urls", "expected"),
    [
        (("git@github.com:iainlane/dotfiles.git",), True),
        (
            (
                "git@github.com:iainlane/dotfiles.git",
                "https://github.com/underwhelmingperformance/dotfiles.git",
            ),
            True,
        ),
        (
            (
                "git@github.com:iainlane/dotfiles.git",
                "https://github.com/nixos/nixpkgs.git",
            ),
            False,
        ),
        (("https://github.com/nixos/nixpkgs.git",), False),
        (("https://gitlab.com/iainlane/dotfiles.git",), False),
        ((), True),
    ],
)
def test_repository_is_owned_when_every_remote_owner_is_configured(
    urls: tuple[str, ...], expected: bool
) -> None:
    assert repository_is_owned(urls, OWNERS) is expected
