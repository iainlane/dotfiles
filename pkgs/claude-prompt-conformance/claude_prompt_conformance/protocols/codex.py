"""Schema-constrained responses produced by Codex roles."""

from typing import Annotated, Literal

import msgspec

NonEmptyString = Annotated[
    str,
    msgspec.Meta(extra_json_schema={"minLength": 1}),
]
Evidence = Annotated[
    tuple[NonEmptyString, ...],
    msgspec.Meta(extra_json_schema={"minItems": 1}),
]
ProgressTitle = Annotated[
    str,
    msgspec.Meta(
        extra_json_schema={
            "minLength": 1,
            "maxLength": 100,
            "pattern": r"^[^\r\n]+$",
        }
    ),
]


class JudgedCriterionResponse(
    msgspec.Struct,
    frozen=True,
    forbid_unknown_fields=True,
):
    identifier: str = msgspec.field(name="id")
    passed: bool
    reason: str
    evidence: Evidence


class JudgementResponse(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    forbid_unknown_fields=True,
):
    criteria: tuple[JudgedCriterionResponse, ...]
    failure_origin: Literal[
        "none",
        "candidate",
        "prompt",
        "fixture",
        "environment",
        "judge",
        "uncertain",
    ]
    summary: str
    recommendation: str
    counterfactual: str
    corrected_response: str
    prompt_observations: tuple[str, ...]


class PromptProposalResponse(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    forbid_unknown_fields=True,
):
    no_change: bool
    title: ProgressTitle
    observations: Annotated[
        tuple[NonEmptyString, ...],
        msgspec.Meta(extra_json_schema={"minItems": 1}),
    ]
    change: str
    reasoning: NonEmptyString
    risks: tuple[str, ...]
    patch: str
