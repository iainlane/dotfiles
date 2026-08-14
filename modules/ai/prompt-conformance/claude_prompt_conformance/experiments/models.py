"""Values produced and compared during a prompt-improvement run."""

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

DECISIVE_IMPROVEMENT = 3
NOISE_TOLERANCE = 1


class AcceptanceFailure(StrEnum):
    """A structural reason an experimental prompt cannot advance."""

    INVALID_EVIDENCE = "invalid-evidence"
    NOT_IMPROVED = "not-improved"
    REGRESSION = "regression"
    GATE_FAILURE = "gate-failure"


@dataclass(frozen=True)
class CriterionScore:
    """How often one fixture criterion passed across an evaluation's samples."""

    fixture: str
    criterion: str
    passed: int
    total: int

    @classmethod
    def unobserved(cls, fixture: str, criterion: str) -> "CriterionScore":
        """Describe a criterion which one side of a comparison never produced."""

        return cls(fixture, criterion, 0, 0)


@dataclass(frozen=True)
class CriterionComparison:
    """How one fixture criterion moved between two prompt evaluations."""

    fixture: str
    criterion: str
    baseline_passed: int
    baseline_total: int
    proposed_passed: int
    proposed_total: int
    change: int
    flaky: bool

    @classmethod
    def between(
        cls,
        baseline: CriterionScore,
        proposed: CriterionScore,
    ) -> "CriterionComparison":
        """Compare one criterion, marking an unstable baseline as flaky."""

        return cls(
            fixture=baseline.fixture,
            criterion=baseline.criterion,
            baseline_passed=baseline.passed,
            baseline_total=baseline.total,
            proposed_passed=proposed.passed,
            proposed_total=proposed.total,
            change=proposed.passed - baseline.passed,
            flaky=0 < baseline.passed < baseline.total,
        )

    @property
    def decisive(self) -> bool:
        """Return whether the criterion improved by more than sampling noise."""

        return self.change >= DECISIVE_IMPROVEMENT

    @property
    def regressed(self) -> bool:
        """Return whether the criterion lost more passes than noise explains."""

        return self.change < -NOISE_TOLERANCE

    @property
    def noise(self) -> bool:
        """Return whether the criterion lost exactly as much as noise explains."""

        return -NOISE_TOLERANCE <= self.change < 0


@dataclass(frozen=True)
class AcceptanceReport:
    """The complete evidence behind one accept-or-reject decision."""

    accepted: bool
    failures: tuple[AcceptanceFailure, ...]
    comparisons: tuple[CriterionComparison, ...]
    decisive_improvement: int
    noise_regressions: int


@dataclass(frozen=True)
class DraftReport:
    """One tournament draft, its title, and how its prompt was judged."""

    draft: str
    title: str
    acceptance: AcceptanceReport


@dataclass(frozen=True)
class ImprovementSummary:
    """The outcome of one bounded tournament and its reserved confirmation."""

    accepted_proposals: int
    attempted_proposals: int
    reserved_checks_accepted: bool
    winner: str | None
    winner_patch: Path | None
    reports: tuple[DraftReport, ...]
