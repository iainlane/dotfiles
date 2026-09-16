from __future__ import annotations

from collections.abc import Sequence

from prose_lint.overrides import Override
from prose_lint.report import Report


def post_tool_use_payload(
    report: Report, overrides: Sequence[Override]
) -> dict[str, object] | None:
    """The PostToolUse hook response for a file prose-lint has just read."""
    payload: dict[str, object] = {}

    if report.errors:
        payload["decision"] = "block"
        payload["reason"] = report.error_text()

    if report.warnings:
        payload["hookSpecificOutput"] = {
            "hookEventName": "PostToolUse",
            "additionalContext": report.warning_text(),
        }

    return _with_overrides(payload, overrides)


def pre_tool_use_payload(
    report: Report, overrides: Sequence[Override]
) -> dict[str, object] | None:
    """The PreToolUse hook response for a commit message about to be written."""
    specific: dict[str, object] = {"hookEventName": "PreToolUse"}

    if report.errors:
        specific["permissionDecision"] = "deny"
        specific["permissionDecisionReason"] = report.error_text()

    if report.warnings:
        specific["additionalContext"] = report.warning_text()

    if len(specific) == 1:
        return _with_overrides({}, overrides)

    return _with_overrides({"hookSpecificOutput": specific}, overrides)


def _with_overrides(
    payload: dict[str, object], overrides: Sequence[Override]
) -> dict[str, object] | None:
    if not payload:
        return None

    if overrides:
        payload["systemMessage"] = "\n".join(
            override.render() for override in overrides
        )

    return payload
