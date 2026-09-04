"""Generate JSON Schemas from the canonical Codex response protocols."""

import argparse
import json
import sys
from collections.abc import Sequence
from enum import StrEnum
from typing import Any

import msgspec

from .codex import JudgementResponse, PromptProposalResponse


class SchemaName(StrEnum):
    """A schema installed for one schema-constrained Codex role."""

    JUDGEMENT = "judgement"
    PROPOSAL = "proposal"


def parser() -> argparse.ArgumentParser:
    """Define the internal schema generator's positional interface."""

    result = argparse.ArgumentParser(description="Generate a Codex response schema")
    result.add_argument("schema", type=SchemaName, choices=tuple(SchemaName))
    return result


def schema_document(name: SchemaName) -> dict[str, Any]:
    """Return the schema generated from the selected response protocol."""

    match name:
        case SchemaName.JUDGEMENT:
            protocol = JudgementResponse
        case SchemaName.PROPOSAL:
            protocol = PromptProposalResponse

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        **msgspec.json.schema(protocol),
    }


def main(argv: Sequence[str] | None = None) -> int:
    """Write one deterministic JSON Schema to standard output."""

    arguments = parser().parse_args(argv)
    json.dump(schema_document(arguments.schema), sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
