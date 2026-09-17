"""Convert LanguageTool's English tagger dictionary to Vale's format.

LanguageTool writes one line per reading, as `word<TAB>lemma<TAB>tag`. Vale
reads one line per word, as `word<TAB>tag[<TAB>tag...]`, and it tags a word
with a single entry that way whatever the surrounding sentence.
"""

from __future__ import annotations

import argparse
import re
from collections.abc import Iterable
from pathlib import Path

# Vale's rules match Penn Treebank tags, so a LanguageTool tag with another
# spelling, such as the punctuation tags, matches nothing.
_TAG = re.compile(r"^[A-Z]+\$?$")

# LanguageTool divides three Penn Treebank tags more finely than Vale's tagger
# does: `NN:U` and `NN:UN` for uncountable nouns, and a suffix on `PRP` and
# `PRP$` for person and number.
_COLLAPSED = {"NN:U": "NN", "NN:UN": "NN"}
_SUFFIXED = ("PRP$", "PRP")

# "that" is left out. Its entry gives Vale a determiner reading, and the
# relative-clause rules then match a clause whose "that" is present, which is
# the clause they exist to accept.
_EXCLUDED = frozenset({"that"})

# SCOWL splits British from American spelling. `english-words` lists the words
# that both variants spell alike, and `british-words` the British forms.
_LISTS = frozenset({"english-words", "british-words"})


def collapse(tag: str) -> str | None:
    """One LanguageTool tag in Vale's spelling, None when Vale has no such tag."""
    collapsed = _COLLAPSED.get(tag, tag)

    for stem in _SUFFIXED:
        if collapsed.startswith(f"{stem}_"):
            collapsed = stem
            break

    return collapsed if _TAG.match(collapsed) else None


def readings(lines: Iterable[str]) -> dict[str, list[str]]:
    """Every single-word entry of the tagger dictionary with its distinct tags."""
    tags: dict[str, list[str]] = {}

    for line in lines:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 3:
            continue

        word, _, tag = fields
        collapsed = collapse(tag)

        if collapsed is None or " " in word or word in _EXCLUDED:
            continue

        found = tags.setdefault(word, [])

        if collapsed not in found:
            found.append(collapsed)

    return tags


def core(directory: Path, largest: int) -> frozenset[str]:
    """The SCOWL words of British English up to and including size `largest`.

    SCOWL grades its word lists by how common the words are, and names each
    file for its grade. A larger grade admits rarer words.
    """
    words: set[str] = set()

    for path in sorted(directory.iterdir()):
        name, _, size = path.name.rpartition(".")

        if name in _LISTS and size.isdigit() and int(size) <= largest:
            words.update(path.read_text(encoding="iso-8859-1").split())

    return frozenset(words)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tagger", type=Path, help="LanguageTool's english-tagger.txt")
    parser.add_argument("scowl", type=Path, help="SCOWL's share/scowl directory")
    parser.add_argument("--largest", type=int, required=True, help="largest SCOWL size")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    vocabulary = core(arguments.scowl, arguments.largest)
    entries = readings(arguments.tagger.read_text().splitlines())
    arguments.output.write_text(
        "".join(
            "\t".join((word, *tags)) + "\n"
            for word, tags in sorted(entries.items())
            if word in vocabulary
        )
    )


if __name__ == "__main__":
    main()
