import pytest

from prose_lint.levels import Level
from prose_lint.relative_clauses import (
    without_contained_duplicates,
    without_fronted_adverbials,
    without_mistagged_adverbials,
)
from prose_lint.report import Finding

PATH = "os/nixos/system.nix"


def alert(match: str, *, line: int = 1, rule: str = "Prose.ZeroRelative") -> Finding:
    return Finding(
        path=PATH,
        line=line,
        column=1,
        rule=rule,
        message="An object-relative clause.",
        severity=Level.error,
        match=match,
    )


@pytest.mark.parametrize(
    ("text", "match"),
    [
        (
            "Outside a git repository the hook has no HEAD to compare with.",
            "repository the hook has",
        ),
        ("On stop the agent closes the transcript.", "stop the agent closes"),
        ("Without this file the account has no key.", "this file the account has"),
        (
            "On both platforms the extension accepts the same flag.",
            "both platforms the extension accepts",
        ),
        ("At startup the runner reads the manifest.", "startup the runner reads"),
        (
            "Under the keys directory the install proceeds.",
            "Under the keys directory the install proceeds",
        ),
        (
            "The hook runs first. Outside a repository the hook has nothing to do.",
            "repository the hook has",
        ),
        (
            "Postgres will not run as root, and at startup it looks up its name.",
            "startup it looks",
        ),
        (
            "On Linux it polls `a.b.c` every `pollMs`; on macOS it reads the style.",
            "macOS it reads",
        ),
        (
            "It covers library APIs, and over a whole repository they outnumber it.",
            "repository they outnumber",
        ),
    ],
)
def test_a_fronted_adverbial_is_dropped(text: str, match: str) -> None:
    assert without_fronted_adverbials((alert(match),), {PATH: text}) == ()


@pytest.mark.parametrize(
    ("text", "match"),
    [
        (
            "The operating system the machine runs is chosen here.",
            "system the machine runs",
        ),
        (
            "In the repository. The option the module declares is listed.",
            "option the module declares",
        ),
        ("Every option this repository declares is listed.", "option this repository"),
        (
            "The tier it belongs to, and the level it runs at, are recorded here.",
            "tier it belongs",
        ),
        (
            (
                "It binds a directory, and on a Nix host its entries are"
                " symlinks into trees the sandbox cannot see."
            ),
            "trees the sandbox cannot see",
        ),
    ],
)
def test_a_clause_with_no_fronted_adverbial_is_kept(text: str, match: str) -> None:
    kept = without_fronted_adverbials((alert(match),), {PATH: text})

    assert kept == (alert(match),)


def test_a_fronted_adverbial_before_a_possessive_subject_is_dropped() -> None:
    finding = alert(
        "the flag Pi's own installer would", rule="Prose.ZeroRelativePossessive"
    )
    text = "Without the flag Pi's own installer would fail."

    assert without_fronted_adverbials((finding,), {PATH: text}) == ()


def test_a_fronted_adverbial_wrapped_over_two_lines_is_dropped() -> None:
    text = "Outside a git\nrepository the hook has no HEAD.\n"

    assert (
        without_fronted_adverbials(
            (alert("repository the hook has", line=2),), {PATH: text}
        )
        == ()
    )


def test_another_rule_is_never_dropped() -> None:
    finding = alert("On stop the agent closes", rule="Prose.EmDash")

    assert without_fronted_adverbials(
        (finding,), {PATH: "On stop the agent closes."}
    ) == (finding,)


def test_a_match_inside_another_on_the_same_line_is_dropped() -> None:
    longer = alert("the option a module declares is")
    shorter = alert("option a module declares", rule="Prose.ZeroRelativeShort")

    assert without_contained_duplicates((longer, shorter)) == (longer,)


def test_the_same_match_on_another_line_is_kept() -> None:
    first = alert("option a module declares")
    second = alert("the option a module declares is", line=9)

    assert without_contained_duplicates((first, second)) == (first, second)


def test_a_match_inside_another_rules_alert_is_kept() -> None:
    other = alert("the option a module declares is", rule="Prose.EmDash")
    relative = alert("option a module declares")

    assert without_contained_duplicates((other, relative)) == (other, relative)


@pytest.mark.parametrize(
    "match",
    [
        "The lint no longer objects",
        "The module no longer exists",
        "The cache no more holds",
    ],
)
def test_a_mistagged_adverbial_is_dropped(match: str) -> None:
    assert without_mistagged_adverbials((alert(match),)) == ()


def test_a_clause_headed_by_no_is_kept() -> None:
    finding = alert("no key this repository sets")

    assert without_mistagged_adverbials((finding,)) == (finding,)


def test_another_rule_keeps_its_mistagged_adverbial() -> None:
    finding = alert("The lint no longer objects", rule="Prose.EmDash")

    assert without_mistagged_adverbials((finding,)) == (finding,)
