"""Command line, signal handling and run assembly for the suite."""

import argparse
import json
import os
import signal
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from types import FrameType
from typing import Protocol

from rich.console import Console

from .backend import (
    RunRequest,
    RunSummary,
    Selection,
    select_fixtures,
)
from .closure_root import (
    nix_store_program,
    pinned_closure,
    runtime_directory,
)
from .composition import ApplicationFactory, acquire_run_authentication
from .demo import DemoApplicationFactory
from .errors import ConformanceError
from .frontend import JsonFrontend, RichFrontend, catalogue_table, choose_fixtures
from .improvement import ImprovementRequest, PromptImprovementSuite
from .improvement import validate_bounds as validate_improvement_bounds
from .inputs import RuntimeInputs, declaration_paths
from .models import Fixture, RuntimeConfiguration
from .process import kill_active_process_groups
from .progress import TaskScopes
from .protocols.configuration import (
    ClaudeConfigurationInput,
    CodexAgentConfigurationInput,
    CodexConfigurationInput,
    IsolationConfigurationInput,
    PromptVariantConfigurationInput,
    RuntimeConfigurationInput,
)
from .run_store import RunInvocation, RunStore, configuration_document
from .slots import SlotPool
from .storage import RunLease


@dataclass(eq=True)
class AllSelectorConflictError(ConformanceError):
    def __str__(self) -> str:
        return "--all cannot be combined with test selectors"


@dataclass(eq=True)
class NameFilterConflictError(ConformanceError):
    def __str__(self) -> str:
        return "test names cannot be combined with category or tag filters"


@dataclass(eq=True)
class ImprovementCalibrationConflictError(ConformanceError):
    def __str__(self) -> str:
        return "--skip-calibration cannot be used during prompt improvement"


@dataclass(eq=True)
class DemoImprovementConflictError(ConformanceError):
    def __str__(self) -> str:
        return "--improve cannot be combined with --demo"


@dataclass(eq=True)
class DuplicateTestNameError(ConformanceError):
    names: tuple[str, ...]

    def __str__(self) -> str:
        return "test names must be unique"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Test Claude's assembled prompt configuration"
    )
    add_suite_arguments(result)
    add_prompt_arguments(result)
    result.add_argument(
        "output",
        nargs="?",
        type=Path,
        metavar="OUTPUT",
        help="directory in which to write or resume results",
    )
    result.add_argument("tests", nargs="*", metavar="TEST")
    result.add_argument(
        "--all",
        action="store_true",
        help="run every test without an interactive menu",
    )
    result.add_argument(
        "--category",
        action="append",
        default=[],
        metavar="CATEGORY",
        help="run tests in a category; may be repeated",
    )
    result.add_argument(
        "--tag",
        action="append",
        default=[],
        metavar="TAG",
        help="run tests with a tag; may be repeated",
    )
    result.add_argument(
        "--list",
        action="store_true",
        help="list available tests and exit",
    )
    result.add_argument(
        "--demo",
        action="store_true",
        help="demonstrate a run with scripted agents; no model requests",
    )
    result.add_argument(
        "--unlink-first",
        action="store_true",
        help="remove a prior run store before starting again",
    )
    result.add_argument(
        "--skip-calibration",
        action="store_true",
        help="run the candidate without checking the judge against reference cases",
    )
    result.add_argument(
        "--keep-workspaces",
        action="store_true",
        help="retain candidate and calibration checkouts in the results",
    )
    result.add_argument(
        "--jobs",
        type=positive_integer,
        default=6,
        metavar="COUNT",
        help="keep at most COUNT agent processes running at once (default: 6)",
    )
    result.add_argument(
        "--improve",
        action="store_true",
        help="run bounded prompt-improvement experiments",
    )
    result.add_argument(
        "--proposals",
        type=positive_integer,
        default=3,
        metavar="COUNT",
        help="race COUNT competing prompt drafts (maximum: 3)",
    )
    result.add_argument(
        "--samples",
        type=positive_integer,
        default=5,
        metavar="COUNT",
        help=(
            "run COUNT fresh samples for each prompt evaluation "
            "(minimum: 3, maximum: 5)"
        ),
    )
    result.add_argument(
        "--format",
        choices=("auto", "rich", "json"),
        default="auto",
        help="output format; auto uses JSON when stdout is not a terminal",
    )
    return result


def add_suite_arguments(result: argparse.ArgumentParser) -> None:
    """Declare the flags that the package wrapper supplies.

    These pin the clients and set the limits that every prompt is measured
    with. A flag repeated on the command line after the wrapper's own replaces
    it.
    """

    group = result.add_argument_group("suite")
    group.add_argument("--fixtures", required=True, metavar="PATH")
    group.add_argument(
        "--isolation-backend",
        required=True,
        choices=("darwin", "linux"),
    )
    group.add_argument("--isolation-program", required=True, metavar="PATH")
    group.add_argument("--git-program", required=True, metavar="PATH")
    group.add_argument("--tls-certificate-bundle", required=True, metavar="PATH")
    group.add_argument("--claude-program", required=True, metavar="PATH")
    group.add_argument("--claude-shell", required=True, metavar="PATH")
    group.add_argument("--claude-version", required=True, metavar="VERSION")
    group.add_argument("--claude-effort", required=True, metavar="EFFORT")
    group.add_argument("--claude-api-budget", required=True, metavar="USD")
    group.add_argument("--claude-oauth-token-url", required=True, metavar="URL")
    group.add_argument("--claude-oauth-client-id", required=True, metavar="ID")
    group.add_argument("--codex-program", required=True, metavar="PATH")
    group.add_argument("--codex-version", required=True, metavar="VERSION")
    group.add_argument("--mcp-program", required=True, metavar="PATH")
    group.add_argument("--judge-schema", required=True, metavar="PATH")
    group.add_argument("--proposal-schema", required=True, metavar="PATH")
    group.add_argument("--judge-effort", required=True, metavar="EFFORT")
    group.add_argument("--improver-effort", required=True, metavar="EFFORT")
    group.add_argument("--codex-service-tier", required=True, metavar="TIER")
    group.add_argument(
        "--codex-verbosity",
        required=True,
        choices=("low", "medium", "high"),
    )
    group.add_argument(
        "--codex-context-window",
        required=True,
        type=int,
        metavar="TOKENS",
    )
    group.add_argument("--codex-oauth-token-url", required=True, metavar="URL")
    group.add_argument("--codex-oauth-client-id", required=True, metavar="ID")
    group.add_argument("--nix-program", required=True, metavar="PATH")
    group.add_argument("--nixpkgs", required=True, metavar="DIR")
    group.add_argument("--variant-expression", required=True, metavar="PATH")
    group.add_argument("--variant-prompt-environment", required=True, metavar="PATH")


def add_prompt_arguments(result: argparse.ArgumentParser) -> None:
    """Declare the flags that describe the prompt configuration under test.

    A caller assembles these: the prompt for the candidate, the managed
    settings for the run, the sources that a variant patches, and the three
    models.
    """

    group = result.add_argument_group("prompt configuration")
    group.add_argument("--managed-settings", required=True, metavar="PATH")
    group.add_argument("--candidate-context", required=True, metavar="DIR")
    group.add_argument("--workspace-overlay", required=True, metavar="DIR")
    group.add_argument("--prompt-context", required=True, metavar="PATH")
    group.add_argument("--prompt-source", required=True, metavar="DIR")
    group.add_argument("--candidate-model", required=True, metavar="MODEL")
    group.add_argument("--output-style", required=True, metavar="NAME")
    group.add_argument("--judge-model", required=True, metavar="MODEL")
    group.add_argument("--improver-model", required=True, metavar="MODEL")


def configuration_input(
    arguments: argparse.Namespace,
) -> RuntimeConfigurationInput:
    return RuntimeConfigurationInput(
        fixture_manifest=arguments.fixtures,
        prompt_context=arguments.prompt_context,
        candidate_context=arguments.candidate_context,
        workspace_overlay=arguments.workspace_overlay,
        git_program=arguments.git_program,
        tls_certificate_bundle=arguments.tls_certificate_bundle,
        claude=ClaudeConfigurationInput(
            program=arguments.claude_program,
            shell=arguments.claude_shell,
            version=arguments.claude_version,
            settings=arguments.managed_settings,
            model=arguments.candidate_model,
            effort=arguments.claude_effort,
            api_budget_usd=arguments.claude_api_budget,
            output_style=arguments.output_style,
            oauth_token_url=arguments.claude_oauth_token_url,
            oauth_client_id=arguments.claude_oauth_client_id,
        ),
        codex=CodexConfigurationInput(
            program=arguments.codex_program,
            version=arguments.codex_version,
            mcp_program=arguments.mcp_program,
            judge=codex_agent_input(
                arguments, arguments.judge_model, arguments.judge_effort
            ),
            improver=codex_agent_input(
                arguments, arguments.improver_model, arguments.improver_effort
            ),
            schema=arguments.judge_schema,
            proposal_schema=arguments.proposal_schema,
            oauth_token_url=arguments.codex_oauth_token_url,
            oauth_client_id=arguments.codex_oauth_client_id,
        ),
        isolation=IsolationConfigurationInput(
            backend=arguments.isolation_backend,
            program=arguments.isolation_program,
        ),
        variant=PromptVariantConfigurationInput(
            nix_program=arguments.nix_program,
            nixpkgs=arguments.nixpkgs,
            expression=arguments.variant_expression,
            prompt_environment=arguments.variant_prompt_environment,
            prompt_source=arguments.prompt_source,
        ),
    )


def codex_agent_input(
    arguments: argparse.Namespace,
    model: str,
    effort: str,
) -> CodexAgentConfigurationInput:
    return CodexAgentConfigurationInput(
        model=model,
        effort=effort,
        service_tier=arguments.codex_service_tier,
        verbosity=arguments.codex_verbosity,
        context_window=arguments.codex_context_window,
    )


def main(argv: Sequence[str] | None = None) -> int:
    signal.signal(signal.SIGTERM, _interrupt_on_terminate)
    try:
        return _main(argv)
    except KeyboardInterrupt:
        return 130


def _interrupt_on_terminate(signum: int, frame: FrameType | None) -> None:
    """Give SIGTERM the interrupt path, so context managers release cleanly."""

    raise KeyboardInterrupt


class Announcer(Protocol):
    """Show the user an urgent notice about the run itself."""

    def announce(self, message: str) -> None: ...


class InterruptEscalation:
    """Stop gracefully on the first interrupt, immediately on the second."""

    def __init__(
        self,
        frontend: Announcer,
        kill: Callable[[], None] = kill_active_process_groups,
        exit_now: Callable[[int], object] = os._exit,
    ) -> None:
        self._frontend = frontend
        self._kill = kill
        self._exit = exit_now
        self._interrupted = False

    def __call__(self, signum: int, frame: FrameType | None) -> None:
        if self._interrupted:
            os.write(
                sys.stderr.fileno(),
                b"\nSecond interrupt: killing agent processes and exiting"
                b" immediately.\n",
            )
            if sys.stdout.isatty():
                # This path never unwinds, so Rich's live display never
                # restores the terminal. Turn synchronised updates off and the
                # cursor back on by hand.
                os.write(sys.stdout.fileno(), b"\x1b[?2026l\x1b[?25h\n")
            self._kill()
            self._exit(130)
            return
        self._interrupted = True
        self._frontend.announce(
            "Interrupt received: stopping agents."
            " Press Ctrl-C again to exit immediately."
        )
        raise KeyboardInterrupt


@dataclass(frozen=True)
class FailurePhase:
    """How far a run had got when it failed, and how that is reported."""

    event: str
    label: str
    status: int


# A caller tells a suite that could not start from one that started and then
# broke, so the two exit with different statuses.
SETUP_FAILURE = FailurePhase("SetupFailed", "Setup failed", 2)
RUN_FAILURE = FailurePhase("RunFailed", "Run failed", 3)


def _main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    declaration = configuration_input(arguments)
    try:
        inputs = RuntimeInputs.from_declaration(declaration)
        fixtures = inputs.source_fixtures()
    except ConformanceError as error:
        return report_failure(SETUP_FAILURE, error, arguments.format)

    rich_output = arguments.format == "rich" or (
        arguments.format == "auto" and sys.stdout.isatty()
    )
    failure_format = "rich" if rich_output else "json"
    console = Console()
    if arguments.list:
        list_fixtures(fixtures, rich_output, console)
        return 0

    if arguments.demo:
        try:
            validate_demo_options(demo=True, improve=arguments.improve)
            selection = selection_from_arguments(
                demo_arguments(arguments),
                fixtures,
                console,
                interactive=rich_output and sys.stdin.isatty(),
            )
            selected = select_fixtures(fixtures, selection)
        except ConformanceError as error:
            return report_failure(SETUP_FAILURE, error, failure_format)

        try:
            summary = run_demo(arguments, inputs, selected, console, rich_output)
        except ConformanceError as error:
            return report_failure(RUN_FAILURE, error, failure_format)

        return exit_status(summary)

    if arguments.output is None:
        parser().error("OUTPUT is required unless --list or --demo is used")

    try:
        selection = selection_from_arguments(
            arguments,
            fixtures,
            console,
            interactive=rich_output and sys.stdin.isatty(),
        )
        selected = select_fixtures(fixtures, selection)
        output = resolve_output(arguments.output)
        validate_run_mode(arguments.improve, arguments.skip_calibration)
        if arguments.improve:
            validate_improvement_bounds(
                ImprovementRequest(
                    output=output,
                    fixtures=selected,
                    proposals=arguments.proposals,
                    samples=arguments.samples,
                    keep_workspaces=arguments.keep_workspaces,
                )
            )
        with (
            pinned_closure(
                declaration_paths(declaration),
                nix_store_program(declaration.variant.nix_program),
                runtime_directory(os.environ),
                f"run-{os.getpid()}",
            ),
            # Authentication needs only the endpoints and the sandbox, and the
            # run store has not written its configuration yet, so this passes
            # the path where the store will write it.
            acquire_run_authentication(
                RuntimeConfiguration.from_input(
                    configuration_document(output),
                    declaration,
                )
            ) as authentication,
            RunLease(output),
        ):
            _, runtime = RunStore.open(
                output,
                inputs,
                RunInvocation(
                    fixtures=tuple(fixture.name for fixture in selected),
                    improve=arguments.improve,
                    calibrate=not arguments.skip_calibration,
                    proposals=arguments.proposals if arguments.improve else 0,
                    samples=arguments.samples if arguments.improve else 0,
                    keep_workspaces=arguments.keep_workspaces,
                ),
                unlink_first=arguments.unlink_first,
            )
            configuration = runtime.configuration
            materialised_by_name = {
                fixture.name: fixture for fixture in runtime.fixtures
            }
            selected = tuple(materialised_by_name[fixture.name] for fixture in selected)
            frontend = (
                RichFrontend(console) if rich_output else JsonFrontend(sys.stdout)
            )
            signal.signal(signal.SIGINT, InterruptEscalation(frontend))
            tasks = TaskScopes(frontend)
            slots = SlotPool(arguments.jobs)
            applications = ApplicationFactory(
                tasks,
                authentication,
                slots,
            )
            try:
                if arguments.improve:
                    summary = PromptImprovementSuite(
                        applications,
                        frontend,
                        tasks,
                        slots,
                    ).run(
                        configuration,
                        ImprovementRequest(
                            output=output,
                            fixtures=selected,
                            proposals=arguments.proposals,
                            samples=arguments.samples,
                            keep_workspaces=arguments.keep_workspaces,
                        ),
                    )
                    return 0 if summary.winner_patch is not None else 1

                application = applications(configuration, frontend)
                summary = application.suite.run(
                    RunRequest(
                        output=output,
                        fixtures=selected,
                        calibrate=not arguments.skip_calibration,
                        keep_workspaces=arguments.keep_workspaces,
                    )
                )
            except ConformanceError as error:
                return report_failure(RUN_FAILURE, error, failure_format)
    except ConformanceError as error:
        return report_failure(SETUP_FAILURE, error, failure_format)

    return exit_status(summary)


def exit_status(summary: RunSummary) -> int:
    return (
        0 if summary.failed == 0 and summary.invalid == 0 and summary.stale == 0 else 1
    )


def run_demo(
    arguments: argparse.Namespace,
    inputs: RuntimeInputs,
    selected: tuple[Fixture, ...],
    console: Console,
    rich_output: bool,
) -> RunSummary:
    """Run the ordinary suite frontend against scripted demo capabilities.

    The result store lives in a temporary directory so scripted evidence can
    never be resumed as if a real run had produced it.
    """

    with TemporaryDirectory(prefix="prompt-conformance-demo-") as temporary:
        output = resolve_output(Path(temporary) / "results")
        with RunLease(output):
            _, runtime = RunStore.open(
                output,
                inputs,
                RunInvocation(
                    fixtures=tuple(fixture.name for fixture in selected),
                    improve=False,
                    calibrate=not arguments.skip_calibration,
                    proposals=0,
                    samples=0,
                    keep_workspaces=False,
                ),
                unlink_first=False,
            )
            materialised_by_name = {
                fixture.name: fixture for fixture in runtime.fixtures
            }
            selected = tuple(materialised_by_name[fixture.name] for fixture in selected)

            frontend = (
                RichFrontend(console) if rich_output else JsonFrontend(sys.stdout)
            )
            signal.signal(signal.SIGINT, InterruptEscalation(frontend))

            applications = DemoApplicationFactory(
                tasks=TaskScopes(frontend),
                slots=SlotPool(arguments.jobs),
            )
            application = applications(runtime.configuration, frontend)

            return application.suite.run(
                RunRequest(
                    output=output,
                    fixtures=selected,
                    calibrate=not arguments.skip_calibration,
                    keep_workspaces=False,
                )
            )


def demo_arguments(arguments: argparse.Namespace) -> argparse.Namespace:
    """Treat every positional as a test name; a demo run has no OUTPUT.

    The parser assigns the first positional to OUTPUT, so without this a
    demo invocation could never select a test by name.
    """

    result = argparse.Namespace(**vars(arguments))
    if result.output is not None:
        result.tests = [str(result.output), *result.tests]
        result.output = None

    return result


def validate_demo_options(*, demo: bool, improve: bool) -> None:
    """Reject `--improve` in a demo run, which makes no model requests to measure."""

    if demo and improve:
        raise DemoImprovementConflictError


def positive_integer(value: str) -> int:
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be at least one")
    return result


def validate_run_mode(improve: bool, skip_calibration: bool) -> None:
    """Reject a combination that would measure drafts with an unvalidated judge."""

    if improve and skip_calibration:
        raise ImprovementCalibrationConflictError


def selection_from_arguments(
    arguments: argparse.Namespace,
    fixtures: tuple[Fixture, ...],
    console: Console,
    *,
    interactive: bool,
) -> Selection:
    selectors = bool(arguments.tests or arguments.category or arguments.tag)
    if arguments.all and selectors:
        raise AllSelectorConflictError
    if arguments.tests and (arguments.category or arguments.tag):
        raise NameFilterConflictError
    if len(arguments.tests) != len(set(arguments.tests)):
        raise DuplicateTestNameError(tuple(arguments.tests))

    if interactive and not arguments.all and not selectors:
        names = choose_fixtures(fixtures, console)
        return Selection(names=names)

    return Selection(
        names=tuple(arguments.tests),
        categories=tuple(arguments.category),
        tags=tuple(arguments.tag),
    )


def resolve_output(output: Path) -> Path:
    expanded = output.expanduser()
    if expanded.is_absolute():
        return expanded.resolve()
    return (Path.cwd() / expanded).resolve()


def list_fixtures(
    fixtures: tuple[Fixture, ...], rich_output: bool, console: Console
) -> None:
    if rich_output:
        console.print(catalogue_table(fixtures))
        return

    value = {
        "event": "TestCatalogue",
        "tests": [
            {
                "name": fixture.name,
                "description": fixture.description,
                "kind": fixture.kind.value,
                "use": fixture.use.value,
                "category": fixture.category,
                "tags": list(fixture.tags),
            }
            for fixture in fixtures
        ],
    }
    print(json.dumps(value, sort_keys=True))


def report_failure(
    phase: FailurePhase,
    error: ConformanceError,
    output_format: str,
) -> int:
    if output_format == "json" or (output_format == "auto" and not sys.stdout.isatty()):
        print(
            json.dumps(
                {
                    "event": phase.event,
                    "error": {
                        "type": type(error).__name__,
                        "description": str(error),
                    },
                }
            )
        )
        return phase.status

    Console(stderr=True).print(f"[red]{phase.label}:[/red] {error}")
    return phase.status


if __name__ == "__main__":
    sys.exit(main())
