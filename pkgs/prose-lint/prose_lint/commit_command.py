from __future__ import annotations

import re
import shlex
from dataclasses import dataclass
from pathlib import Path

_HEREDOC = re.compile(
    r"<<-?[ \t]*(?P<quote>['\"]?)(?P<delimiter>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)"
)
_SHORT_OPTION = re.compile(r"^-(?P<flags>[A-Za-z]*?)(?P<final>[mF])(?P<value>.*)$")
_CONSUMED_SUBSTITUTION = re.compile(r"^\$\(\s*cat\s*\)$")
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_PRECEDING_TOKENS = frozenset(
    {
        "&&",
        "||",
        ";",
        "|",
        "(",
        "{",
        "then",
        "do",
        "else",
        "exec",
        "env",
        "sudo",
        "command",
    }
)


@dataclass(frozen=True)
class _Heredoc:
    body: str
    remainder: str


def extract_commit_message(command: str, cwd: Path) -> str | None:
    """The commit message a shell command would hand to git, if it has one.

    Returns None for anything else, including a `git commit` that would open an
    editor, so a hook can stay out of the way of every other command.
    """
    heredoc = _split_heredoc(command)
    tokens = _split(command if heredoc is None else heredoc.remainder)

    if tokens is None:
        return None

    arguments = _commit_arguments(tokens)
    if arguments is None:
        return None

    messages, message_file = _read_options(arguments)

    if message_file == "-":
        return None if heredoc is None else heredoc.body

    if message_file is not None:
        path = Path(message_file)
        resolved = path if path.is_absolute() else cwd / path

        return _read_message_file(resolved)

    if heredoc is not None:
        messages = [
            heredoc.body if _CONSUMED_SUBSTITUTION.match(" ".join(m.split())) else m
            for m in messages
        ]

    if messages:
        return "\n\n".join(messages)

    return None


def _read_message_file(path: Path) -> str | None:
    try:
        return path.read_text()
    except (OSError, UnicodeDecodeError):
        return None


def _split(command: str) -> list[str] | None:
    try:
        return shlex.split(command)
    except ValueError:
        return None


def _split_heredoc(command: str) -> _Heredoc | None:
    match = _HEREDOC.search(command)
    if match is None:
        return None

    after = command[match.end() :]
    break_index = after.find("\n")
    if break_index < 0:
        return None

    delimiter = match.group("delimiter")
    lines = after[break_index + 1 :].split("\n")

    for index, line in enumerate(lines):
        if line.strip() != delimiter:
            continue

        remainder = "".join(
            [
                command[: match.start()],
                after[:break_index],
                "\n",
                "\n".join(lines[index + 1 :]),
            ]
        )
        body = "".join(f"{line}\n" for line in lines[:index])

        return _Heredoc(body=body, remainder=remainder)

    return None


def _commit_arguments(tokens: list[str]) -> list[str] | None:
    try:
        position = tokens.index("commit")
    except ValueError:
        return None

    if not any(
        Path(token).name == "git" and _starts_a_command(tokens, index)
        for index, token in enumerate(tokens[:position])
    ):
        return None

    return tokens[position + 1 :]


def _starts_a_command(tokens: list[str], index: int) -> bool:
    """Whether the token at `index` is in command position.

    A word that merely appears among a command's arguments, as in
    `printf '%s' git commit -m text`, is not the git command.
    """
    for previous in reversed(tokens[:index]):
        if _ASSIGNMENT.match(previous):
            continue

        return previous in _PRECEDING_TOKENS or previous.endswith((";", "&&", "||"))

    return True


def _read_options(arguments: list[str]) -> tuple[list[str], str | None]:
    messages: list[str] = []
    message_file: str | None = None
    index = 0

    while index < len(arguments):
        argument = arguments[index]
        value: str | None = None
        kind: str | None = None

        if argument in {"-m", "--message"}:
            kind = "m"
        elif argument in {"-F", "--file"}:
            kind = "F"
        elif argument.startswith("--message="):
            kind, value = "m", argument[len("--message=") :]
        elif argument.startswith("--file="):
            kind, value = "F", argument[len("--file=") :]
        else:
            short = _SHORT_OPTION.match(argument)
            if short is not None:
                kind = short.group("final")
                value = short.group("value") or None

        if kind is None:
            index += 1
            continue

        if value is None:
            index += 1
            if index >= len(arguments):
                break
            value = arguments[index]

        if kind == "m":
            messages.append(value)
        else:
            message_file = value

        index += 1

    return messages, message_file
