"""Compatibility imports for model-client adapters."""

from .agents import ClaudeCandidateAgent, CodexJudge, CodexPromptImprover
from .agents.candidate import (
    candidate_settings,
    canonical_action,
    canonical_actions,
    parse_claude_response,
    read_json_lines,
)
from .agents.improver import prompt_improver_prompt
from .agents.judge import evaluator_mcp_configuration, judge_prompt

__all__ = [
    "ClaudeCandidateAgent",
    "CodexJudge",
    "CodexPromptImprover",
    "candidate_settings",
    "canonical_action",
    "canonical_actions",
    "evaluator_mcp_configuration",
    "judge_prompt",
    "parse_claude_response",
    "prompt_improver_prompt",
    "read_json_lines",
]
