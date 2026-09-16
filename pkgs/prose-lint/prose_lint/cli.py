from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from pathlib import Path

from prose_lint.commit_command import extract_commit_message
from prose_lint.config import Config, share_directory
from prose_lint.git import SubprocessGit
from prose_lint.hooks import post_tool_use_payload, pre_tool_use_payload
from prose_lint.levels import Level
from prose_lint.overrides import OverrideRefused, build_override
from prose_lint.report import ADVICE
from prose_lint.rules import RuleCatalogue
from prose_lint.runtime import Runtime
from prose_lint.vale import SubprocessVale, ValeFailed, ValeMissing

_SCISSORS = "------------------------ >8 ------------------------"
_EDIT_TOOLS = {"Edit", "Write", "MultiEdit"}


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    arguments = parser.parse_args(argv)

    try:
        return arguments.run(arguments)
    except (ValeFailed, ValeMissing) as failure:
        print(f"prose-lint: {failure}", file=sys.stderr)
        return 2


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="prose-lint",
        description="Lint prose against the Plain technical prose style.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check", help="lint files")
    check.add_argument("files", nargs="*", type=Path)
    check.add_argument("--format", choices=["line", "json"], default="line")
    check.set_defaults(run=_check)

    commit = commands.add_parser("commit-msg", help="lint a commit message file")
    commit.add_argument("file", type=Path)
    commit.set_defaults(run=_commit_msg)

    allow = commands.add_parser("allow", help="lower a rule in this repository")
    allow.add_argument("rule")
    allow.add_argument("--because", required=True)
    allow.add_argument(
        "--level", choices=["warning", "suggestion", "NO"], default="warning"
    )
    allow.set_defaults(run=_allow)

    disallow = commands.add_parser("disallow", help="remove an override")
    disallow.add_argument("rule")
    disallow.set_defaults(run=_disallow)

    listing = commands.add_parser("overrides", help="list the overrides in force")
    listing.set_defaults(run=_overrides)

    hook = commands.add_parser("hook", help="answer a Claude Code hook")
    hook.add_argument("event", choices=["post-tool-use", "pre-tool-use"])
    hook.set_defaults(run=_hook)

    return parser


def _runtime(cwd: Path | None = None, session_id: str | None = None) -> Runtime:
    working = cwd or Path.cwd()
    share = share_directory()

    return Runtime(
        share=share,
        catalogue=RuleCatalogue.load(share / "tiers.toml"),
        config=Config.load(),
        git=SubprocessGit(cwd=working),
        vale=SubprocessVale(cwd=working),
        cwd=working,
        session_id=session_id or os.environ.get("PROSE_LINT_SESSION_ID") or "default",
    )


def _check(arguments: argparse.Namespace) -> int:
    if not arguments.files:
        return 0

    runtime = _runtime()
    files = tuple(path for path in arguments.files if runtime.catalogue.lintable(path))
    report = runtime.lint_paths(files)

    if arguments.format == "json":
        print(report.render_json())
        return 1 if report.errors else 0

    if report.findings:
        print(report.render_lines())

    if report.errors:
        print()
        print(ADVICE)

    return 1 if report.errors else 0


def _commit_msg(arguments: argparse.Namespace) -> int:
    runtime = _runtime()
    text = strip_commit_comments(arguments.file.read_text())
    report = runtime.lint_commit_message(text, str(arguments.file))

    if report.errors:
        print(report.error_text())

    if report.warnings:
        print(report.warning_text())

    return 1 if report.errors else 0


def strip_commit_comments(text: str) -> str:
    """The message git would keep: no comment lines and nothing past the scissors."""
    lines: list[str] = []

    for line in text.splitlines():
        if _SCISSORS in line:
            break

        if line.startswith("#"):
            continue

        lines.append(line)

    return "".join(f"{line}\n" for line in lines)


def _allow(arguments: argparse.Namespace) -> int:
    runtime = _runtime()

    try:
        override = build_override(
            runtime.catalogue,
            name=arguments.rule,
            because=arguments.because,
            level=Level.parse(arguments.level),
            root=runtime.root,
        )
    except OverrideRefused as refusal:
        print(refusal, file=sys.stderr)
        return 1

    runtime.record_override(override)
    print(override.render())

    return 0


def _disallow(arguments: argparse.Namespace) -> int:
    runtime = _runtime()

    if not runtime.drop_override(arguments.rule):
        print(f"{arguments.rule} has no override here.", file=sys.stderr)
        return 1

    print(f"{arguments.rule} runs at its configured level again.")

    return 0


def _overrides(_: argparse.Namespace) -> int:
    runtime = _runtime()
    overrides = runtime.overrides()

    if not overrides:
        print("No rule is lowered here.")
        return 0

    for override in overrides:
        print(override.render())

    return 0


def _hook(arguments: argparse.Namespace) -> int:
    try:
        response = _answer_hook(arguments.event, sys.stdin.read())
    except Exception as failure:  # noqa: BLE001
        response = {"systemMessage": f"prose-lint did not run: {failure}"}

    if response is not None:
        print(json.dumps(response))

    return 0


def _answer_hook(event: str, raw_payload: str) -> dict[str, object] | None:
    """The response to one hook payload, or None when no rule applies.

    Any failure propagates to the caller, which reports it to the user and
    exits 0: a hook that exits non-zero would be reported as a hook error on
    every edit or command.
    """
    payload = json.loads(raw_payload or "{}")
    if not isinstance(payload, dict):
        return None

    cwd = Path(payload.get("cwd") or Path.cwd())
    runtime = _runtime(cwd=cwd, session_id=payload.get("session_id"))

    if event == "post-tool-use":
        return _post_tool_use(runtime, payload)

    return _pre_tool_use(runtime, payload)


def _post_tool_use(
    runtime: Runtime, payload: dict[str, object]
) -> dict[str, object] | None:
    if payload.get("tool_name") not in _EDIT_TOOLS:
        return None

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None

    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str) or not Path(file_path).is_file():
        return None

    if not runtime.catalogue.lintable(Path(file_path)):
        return None

    report = runtime.lint_paths((Path(file_path),))

    return post_tool_use_payload(report, runtime.overrides())


def _pre_tool_use(
    runtime: Runtime, payload: dict[str, object]
) -> dict[str, object] | None:
    if payload.get("tool_name") != "Bash":
        return None

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None

    command = tool_input.get("command")
    if not isinstance(command, str):
        return None

    message = extract_commit_message(command, runtime.cwd)
    if message is None:
        return None

    report = runtime.lint_commit_message(message, "commit message")

    return pre_tool_use_payload(report, runtime.overrides())


if __name__ == "__main__":
    raise SystemExit(main())
