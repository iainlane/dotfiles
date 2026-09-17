from prose_lint.hooks import (
    post_tool_use_payload,
    pre_tool_use_payload,
    stop_payload,
)
from prose_lint.levels import Level
from prose_lint.overrides import Override
from prose_lint.report import Finding, Report

ERROR = Finding(
    path="README.md",
    line=3,
    column=12,
    rule="Prose.ArrowChain",
    message="'host -> features' compresses a relationship into an arrow.",
    severity=Level.error,
)
WARNING = Finding(
    path="README.md",
    line=5,
    column=1,
    rule="Prose.WarningVerbs",
    message="'contains' or 'keeps' is more specific than 'holds'.",
    severity=Level.warning,
)

ERROR_TEXT = (
    "errors\n"
    "README.md:3:12 Prose.ArrowChain: 'host -> features' compresses a "
    "relationship into an arrow.\n"
    "\n"
    "Where this project's conventions require otherwise, lower a rule with "
    '`prose-lint allow <Rule> --because "<reason pointing at a file in the '
    'repository>"`. A locked rule cannot be lowered.'
)
WARNING_TEXT = (
    "warnings\n"
    "README.md:5:1 Prose.WarningVerbs: 'contains' or 'keeps' is more specific "
    "than 'holds'."
)


def test_errors_block_the_edit() -> None:
    assert post_tool_use_payload(Report((ERROR,)), ()) == {
        "decision": "block",
        "reason": ERROR_TEXT,
    }


def test_warnings_reach_the_model_as_context() -> None:
    assert post_tool_use_payload(Report((WARNING,)), ()) == {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": WARNING_TEXT,
        }
    }


def test_errors_and_warnings_appear_together() -> None:
    assert post_tool_use_payload(Report((ERROR, WARNING)), ()) == {
        "decision": "block",
        "reason": ERROR_TEXT,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": WARNING_TEXT,
        },
    }


def test_no_findings_produce_no_payload() -> None:
    assert post_tool_use_payload(Report(()), ()) is None


def test_overrides_in_force_are_reported_to_the_user() -> None:
    override = Override(rule="Latin", level=Level.warning, because="docs/style.md")

    assert post_tool_use_payload(Report((WARNING,)), (override,)) == {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": WARNING_TEXT,
        },
        "systemMessage": "prose-lint runs Latin at warning: docs/style.md",
    }


def test_a_commit_message_with_errors_is_denied() -> None:
    assert pre_tool_use_payload(Report((ERROR,)), ()) == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": ERROR_TEXT,
        }
    }


def test_a_commit_message_with_only_warnings_is_not_denied() -> None:
    assert pre_tool_use_payload(Report((WARNING,)), ()) == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": WARNING_TEXT,
        }
    }


def test_a_clean_commit_message_produces_no_payload() -> None:
    assert pre_tool_use_payload(Report(()), ()) is None


def test_a_long_list_of_findings_is_cut_with_a_count() -> None:
    findings = tuple(
        Finding(
            path="README.md",
            line=line,
            column=1,
            rule="Prose.EmDash",
            message="em dash",
            severity=Level.error,
        )
        for line in range(1, 31)
    )

    text = Report(findings).error_text()

    assert text.splitlines()[1:27] == [
        f"README.md:{line}:1 Prose.EmDash: em dash" for line in range(1, 26)
    ] + ["and 5 more"]


def test_errors_on_added_lines_block_the_stop() -> None:
    assert stop_payload(Report((ERROR,)), ()) == {
        "decision": "block",
        "reason": ERROR_TEXT,
    }


def test_warnings_on_added_lines_reach_the_user_as_a_system_message() -> None:
    assert stop_payload(Report((WARNING,)), ()) == {"systemMessage": WARNING_TEXT}


def test_added_lines_with_no_findings_produce_no_payload() -> None:
    assert stop_payload(Report(()), ()) is None
