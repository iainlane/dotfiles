import argparse
import asyncio
import contextlib
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import BinaryIO, Literal

import structlog
from bson import ObjectId
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter
from pymongo import MongoClient
from structlog.typing import Processor

PORTS = (
    "mongodb",
    "postgres",
    "redis",
    "meilisearch",
    "objects",
    "objectsConsole",
    "iron",
    "controller",
    "archive",
    "codeApi",
    "fileServer",
    "toolServer",
    "egressGateway",
    "workerHealth",
    "librechat",
)
EMAIL = "startup@example.com"
PASSWORD = "LibreChat-startup-fixture-2026!"
INITIAL_NAME = "Startup Fixture"
NAME = "Renamed Fixture"
ANSI_COLOUR = re.compile(r"\x1b\[[0-9;]*m")
ERROR_LOG = re.compile(r"\berror:")
PROVISIONING_STARTED = "LibreChat bootstrap provisioning started."
LOG = structlog.stdlib.get_logger()


class StartupConfiguration(BaseModel):
    model_config = ConfigDict(extra="forbid")

    manifest: Path
    runtime: Path
    fixture_command: list[str] = Field(alias="fixtureCommand", min_length=1)
    fixture_package_root: Path = Field(alias="fixturePackageRoot")
    command: list[str] = Field(min_length=1)
    environment: dict[str, str] | list[str] | None = None
    working_directory: Path = Field(alias="workingDirectory")

    def service_environment(self) -> dict[str, str]:
        if self.environment is None:
            return {}

        if isinstance(self.environment, dict):
            return self.environment.copy()

        environment: dict[str, str] = {}

        for assignment in self.environment:
            key, separator, value = assignment.partition("=")

            if not separator or not key:
                raise ValueError(
                    f"Invalid service environment assignment: {assignment!r}"
                )

            environment[key] = value

        return environment


class HostPrograms(BaseModel):
    model_config = ConfigDict(extra="allow")

    librechat: Path


class HostManifest(BaseModel):
    model_config = ConfigDict(extra="allow")

    programs: HostPrograms
    hook_command: Path = Field(alias="hookCommand")
    home_directory: Path = Field(alias="homeDirectory")
    state_directory: Path = Field(alias="stateDirectory")
    socket_directory: Path | None = Field(default=None, alias="socketDirectory")
    ports: dict[str, int] = Field(default_factory=dict)
    models: dict[str, str]
    mcp_servers: dict[str, dict[str, object]] = Field(alias="mcpServers")
    chat_prompt: str = Field(alias="chatPrompt", min_length=1)


class ProtocolFixture(BaseModel):
    origin: str
    server_name: str = Field(alias="serverName")
    mcp_server: dict[str, object] = Field(alias="mcpServer")
    model: str


class DatabaseConnection(BaseModel):
    mongo_uri: str = Field(alias="mongoUri")


class BootstrapAccount(BaseModel):
    user_id: str = Field(alias="userId")


class Account(BaseModel):
    email: str
    role: str
    name: str


class LoginResponse(BaseModel):
    user: Account
    token: str


class ChatPromptSelection(BaseModel):
    mode: Literal["inherit"]


class EffectiveChatPrompt(BaseModel):
    group_id: str = Field(alias="groupId", pattern=r"^[a-f0-9]{24}$")
    prompt_id: str = Field(alias="promptId", pattern=r"^[a-f0-9]{24}$")
    name: str
    source: Literal["config"]


class ChatPromptPreferences(BaseModel):
    selection: ChatPromptSelection
    effective_prompt: EffectiveChatPrompt = Field(alias="effectivePrompt")


class ManagedPromptRevision(BaseModel):
    id: str = Field(alias="_id", pattern=r"^[a-f0-9]{24}$")
    group_id: str = Field(alias="groupId", pattern=r"^[a-f0-9]{24}$")
    prompt: str
    type: Literal["text"]


class ManagedPromptGroup(BaseModel):
    id: str = Field(alias="_id", pattern=r"^[a-f0-9]{24}$")
    name: str
    oneliner: str
    source: Literal["config"]
    production_id: str = Field(alias="productionId", pattern=r"^[a-f0-9]{24}$")
    production_prompt: ManagedPromptRevision = Field(alias="productionPrompt")


class Arguments(argparse.Namespace):
    configuration: Path


def configure_logging() -> None:
    logging.basicConfig(format="%(message)s", stream=sys.stderr, level=logging.INFO)
    processors: list[Processor] = [
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
    ]

    if sys.stderr.isatty():
        processors.append(structlog.dev.ConsoleRenderer())
    else:
        processors.extend(
            [
                structlog.processors.ExceptionRenderer(
                    structlog.tracebacks.ExceptionDictTransformer(show_locals=False)
                ),
                structlog.processors.JSONRenderer(),
            ]
        )

    structlog.configure(
        processors=processors,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )


def response(
    url: str,
    body: dict[str, str] | None = None,
    timeout: float = 10,
    *,
    token: str | None = None,
) -> tuple[int, bytes]:
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        headers=headers,
    )

    try:
        result = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as failure:
        result = failure

    with result:
        status = result.status

        if not isinstance(status, int):
            raise TypeError("HTTP response did not include a numeric status")

        return status, result.read()


def verify_chat_prompt(base_url: str, token: str, prompt: str) -> None:
    status, body = response(base_url + "/api/prompts/default", token=token)
    assert status == 200, f"Chat prompt preferences returned HTTP {status}"
    preferences = ChatPromptPreferences.model_validate_json(body)
    effective = preferences.effective_prompt
    assert preferences.model_dump(by_alias=True) == {
        "selection": {"mode": "inherit"},
        "effectivePrompt": {
            "groupId": effective.group_id,
            "promptId": effective.prompt_id,
            "name": "General assistant",
            "source": "config",
        },
    }

    status, body = response(base_url + "/api/prompts/all", token=token)
    assert status == 200, f"Prompt Library returned HTTP {status}"
    groups = TypeAdapter(list[ManagedPromptGroup]).validate_json(body)
    assert [group.model_dump(by_alias=True) for group in groups] == [
        {
            "_id": effective.group_id,
            "name": "General assistant",
            "oneliner": "A general assistant for everyday conversations.",
            "source": "config",
            "productionId": effective.prompt_id,
            "productionPrompt": {
                "_id": effective.prompt_id,
                "groupId": effective.group_id,
                "prompt": prompt,
                "type": "text",
            },
        }
    ]
    LOG.info("chat_prompt_default_succeeded")


def available(url: str) -> bool:
    try:
        return response(url, timeout=1)[0] == 200
    except (OSError, urllib.error.URLError):
        return False


def listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


def contains(path: Path, message: str) -> bool:
    with path.open(errors="replace") as lines:
        return any(message in line for line in lines)


def wait_for(
    process: subprocess.Popen[bytes], probe: Callable[[], bool], description: str
) -> None:
    deadline = time.monotonic() + 90

    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(
                f"Service exited with status {process.returncode} "
                f"while waiting for {description}"
            )

        if probe():
            LOG.info("service_ready", check=description)
            return

        time.sleep(0.1)

    raise AssertionError(f"Timed out waiting for {description}")


def stop(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        process.terminate()

    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
        raise


async def bootstrap_account(
    configuration: StartupConfiguration,
    manifest: Path,
    password: Path,
    environment: dict[str, str],
    output: BinaryIO,
    name: str,
) -> None:
    command = [
        str(configuration.runtime),
        "bootstrap",
        str(manifest),
        "--email",
        EMAIL,
        "--name",
        name,
        "--password-file",
        str(password),
    ]
    process = await asyncio.create_subprocess_exec(
        *command,
        cwd=manifest.parent,
        env=environment,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        start_new_session=True,
    )
    errors_seen = False
    completed = False
    started = False

    try:
        async with asyncio.timeout(90) as deadline:
            assert process.stdout is not None

            async for raw_line in process.stdout:
                output.write(raw_line)
                output.flush()
                line = ANSI_COLOUR.sub("", raw_line.decode(errors="replace")).rstrip()
                if not started and line.endswith(PROVISIONING_STARTED):
                    started = True
                    deadline.reschedule(asyncio.get_running_loop().time() + 60)

                is_error = ERROR_LOG.search(line) is not None
                errors_seen |= is_error
                completed |= line == "LibreChat account bootstrap completed."
                LOG.log(
                    logging.ERROR if is_error else logging.INFO,
                    "bootstrap_output",
                    line=line,
                )

            status = await process.wait()

        if status != 0:
            raise subprocess.CalledProcessError(status, command)

        if errors_seen:
            raise AssertionError("Bootstrap emitted error logs")

        if not started:
            raise AssertionError("Bootstrap did not report readiness for provisioning")

        if not completed:
            raise AssertionError("Bootstrap did not emit its completion message")
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)

            await asyncio.wait_for(process.wait(), timeout=10)


def verify_bootstrap_name_validation(
    configuration: StartupConfiguration,
    manifest: Path,
    environment: dict[str, str],
) -> None:
    invalid_state = manifest.parent / "invalid-bootstrap-state"
    invalid_manifest = manifest.parent / "invalid-bootstrap.json"
    data = HostManifest.model_validate_json(manifest.read_text()).model_copy(
        update={"state_directory": invalid_state}
    )
    invalid_manifest.write_text(data.model_dump_json(by_alias=True))

    for name in (None, "", "   ", "ab", "a" * 81):
        command = [
            str(configuration.runtime),
            "bootstrap",
            str(invalid_manifest),
            "--email",
            EMAIL,
            "--password-file",
            str(invalid_state / "password"),
        ]
        if name is not None:
            command.extend(["--name", name])

        result = subprocess.run(
            command, env=environment, capture_output=True, timeout=10, check=False
        )
        assert {
            "failed": result.returncode != 0,
            "name_error": b'"name"' in result.stderr,
            "state_created": invalid_state.exists(),
        } == {"failed": True, "name_error": True, "state_created": False}


def verify_agent_selection(
    state_directory: Path, bootstrap: Callable[[str], None]
) -> None:
    bootstrap(INITIAL_NAME)
    connection = DatabaseConnection.model_validate_json(
        (state_directory / "connection.json").read_text()
    )
    account = BootstrapAccount.model_validate_json(
        (state_directory / "account.json").read_text()
    )
    with MongoClient[dict[str, object]](
        connection.mongo_uri, serverSelectionTimeoutMS=5000, timeoutMS=5000
    ) as client:
        agents = client["LibreChat"]["agents"]
        users = client["LibreChat"]["users"]
        user_query = {"_id": ObjectId(account.user_id)}
        user_projection = {"_id": False, "name": True, "password": True}
        original_user = users.find_one(user_query, user_projection)
        assert original_user is not None
        assert original_user["name"] == INITIAL_NAME
        query = {"author": ObjectId(account.user_id)}
        expected = {"tools": ["execute_code", "sys__all__sys_mcp_oauth-fixture"]}
        projection = {"_id": False, "tools": True}
        assert agents.find_one(query, projection) == expected
        original = agents.find_one(query, {**projection, "versions": True})
        bootstrap(f"  {NAME}  ")
        assert agents.find_one(query, {**projection, "versions": True}) == original
        assert users.find_one(user_query, user_projection) == {
            **original_user,
            "name": NAME,
        }
        LOG.info("agent_selection_succeeded")


def run(configuration: StartupConfiguration) -> None:
    with (
        tempfile.TemporaryDirectory(prefix="librechat-startup-") as temporary,
        tempfile.TemporaryDirectory(prefix="lcs-", dir="/tmp") as sockets,
        contextlib.ExitStack() as reservations,
        contextlib.ExitStack() as fixtures,
    ):
        home = Path(temporary)
        manifest = HostManifest.model_validate_json(configuration.manifest.read_text())
        original_home = manifest.home_directory
        original_state = manifest.state_directory
        manifest.home_directory = home
        manifest.state_directory = home / "state"
        manifest.socket_directory = Path(sockets)
        manifest.ports = {}

        for name in PORTS:
            listener = reservations.enter_context(socket.socket())
            listener.bind(("127.0.0.1", 0))
            manifest.ports[name] = listener.getsockname()[1]

        ports = manifest.ports
        base_url = f"http://127.0.0.1:{ports['librechat']}"
        fixture_log = fixtures.enter_context((home / "protocol-fixture.log").open("ab"))
        ready = home / "protocol-fixture.json"
        fixture_process = subprocess.Popen(
            [
                *configuration.fixture_command,
                "serve",
                "--ready-file",
                str(ready),
                "--package-root",
                str(configuration.fixture_package_root),
            ],
            stdout=fixture_log,
            stderr=fixture_log,
            start_new_session=True,
        )
        fixtures.callback(stop, fixture_process)
        wait_for(fixture_process, ready.exists, "protocol fixture is ready")
        fixture = ProtocolFixture.model_validate_json(ready.read_text())
        manifest.mcp_servers = {fixture.server_name: fixture.mcp_server}
        manifest.models["anthropic"] = fixture.model
        fixture_environment = {
            "ANTHROPIC_REVERSE_PROXY": fixture.origin,
            "ANTHROPIC_MODELS": fixture.model,
            "DOMAIN_SERVER": base_url,
            "DOMAIN_CLIENT": base_url,
        }
        original_launcher = str(manifest.programs.librechat)
        launcher = home / "librechat-server"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "import os\n"
            "import sys\n"
            "assert os.environ['LIBRECHAT_CODE_DEFAULT_PROFILE'] == 'stateful'\n"
            f"os.environ.update({fixture_environment!r})\n"
            f"os.execv({original_launcher!r}, [{original_launcher!r}, *sys.argv[1:]])\n"
        )
        launcher.chmod(0o700)
        manifest.programs.librechat = launcher
        hook = home / "workspace-reminder"
        hook_source = manifest.hook_command.read_text()
        assert hook_source.count(str(original_state)) == 1
        hook.write_text(
            hook_source.replace(str(original_state), str(manifest.state_directory))
        )
        hook.chmod(0o700)
        manifest.hook_command = hook
        fixture_manifest = home / "manifest.json"
        fixture_manifest.write_text(manifest.model_dump_json(by_alias=True))
        service = Path(configuration.command[0])
        command = service.read_text()
        assert command.count(str(configuration.manifest)) == 1
        fixture_service = home / "service"
        fixture_service.write_text(
            command.replace(str(configuration.manifest), str(fixture_manifest))
        )
        fixture_service.chmod(0o700)
        password = home / "password"
        password.write_text(PASSWORD)
        password.chmod(0o600)
        working_directory = configuration.working_directory

        if working_directory == original_home:
            working_directory = home

        environment = {
            **os.environ,
            **configuration.service_environment(),
            "HOME": temporary,
        }
        log = home / "service.log"
        reservations.close()

        try:
            for first_start in (True, False):
                with log.open("ab") as output:
                    process = subprocess.Popen(
                        [str(fixture_service), *configuration.command[1:]],
                        cwd=working_directory,
                        env=environment,
                        stdout=output,
                        stderr=output,
                        start_new_session=True,
                    )

                    try:
                        if first_start:
                            wait_for(
                                process,
                                lambda: (
                                    contains(log, "LibreChat databases are ready.")
                                    and available(
                                        f"http://127.0.0.1:{ports['meilisearch']}/health"
                                    )
                                    and listening(ports["objects"])
                                ),
                                "native databases are ready for account bootstrap",
                            )

                            verify_bootstrap_name_validation(
                                configuration, fixture_manifest, environment
                            )

                            def bootstrap_fixture(name: str) -> None:
                                asyncio.run(
                                    bootstrap_account(
                                        configuration,
                                        fixture_manifest,
                                        password,
                                        environment,
                                        output,
                                        name,
                                    )
                                )

                            verify_agent_selection(
                                manifest.state_directory, bootstrap_fixture
                            )

                        wait_for(
                            process,
                            lambda: available(base_url + "/health"),
                            "LibreChat is healthy",
                        )
                        wait_for(
                            process,
                            lambda: available(base_url + "/readyz"),
                            "LibreChat is ready for inference",
                        )
                        runtime_config = json.loads(
                            (manifest.state_directory / "librechat.json").read_text()
                        )
                        assert {
                            "modelSelect": runtime_config["interface"]["modelSelect"],
                            "modelSpecs": runtime_config.get("modelSpecs"),
                            "prompts": runtime_config["prompts"],
                            "allowedEnvironments": runtime_config["endpoints"][
                                "agents"
                            ]["statefulCodeSessions"]["allowedEnvironments"],
                            "deferred_tools": "deferred_tools"
                            in runtime_config["endpoints"]["agents"]["capabilities"],
                            "authorizationMode": runtime_config["mcpSettings"][
                                "authorizationMode"
                            ],
                        } == {
                            "modelSelect": True,
                            "modelSpecs": None,
                            "prompts": {
                                "library": [
                                    {
                                        "id": "general-assistant",
                                        "name": "General assistant",
                                        "description": "A general assistant for everyday conversations.",
                                        "prompt": manifest.chat_prompt,
                                    }
                                ],
                                "defaultChatPrompt": "general-assistant",
                            },
                            "allowedEnvironments": ["conversation"],
                            "deferred_tools": True,
                            "authorizationMode": "nonblocking",
                        }
                        status, page = response(base_url + "/")
                        assert {
                            "status": status,
                            "application": b"LibreChat" in page,
                        } == {
                            "status": 200,
                            "application": True,
                        }
                        status, body = response(
                            base_url + "/api/auth/login",
                            {
                                "email": EMAIL,
                                "password": PASSWORD,
                            },
                        )

                        if status != 200:
                            raise AssertionError(
                                f"Login returned HTTP {status}: {body.decode()}"
                            )

                        login = LoginResponse.model_validate_json(body)
                        assert {
                            "status": status,
                            "user": login.user.model_dump(),
                            "token": bool(login.token),
                        } == {
                            "status": 200,
                            "user": {"email": EMAIL, "role": "ADMIN", "name": NAME},
                            "token": True,
                        }
                        LOG.info(
                            "login_succeeded",
                            phase="bootstrap" if first_start else "restart",
                        )
                        verify_chat_prompt(base_url, login.token, manifest.chat_prompt)
                        if first_start:
                            subprocess.run(
                                [
                                    *configuration.fixture_command,
                                    "verify",
                                    "--base-url",
                                    base_url,
                                    "--fixture-url",
                                    fixture.origin,
                                    "--email",
                                    EMAIL,
                                ],
                                env={
                                    **environment,
                                    "LIBRECHAT_TEST_PASSWORD": PASSWORD,
                                },
                                stdout=output,
                                stderr=output,
                                timeout=120,
                                check=True,
                            )
                            LOG.info("nonblocking_mcp_flow_succeeded")
                    finally:
                        stop(process)
        except Exception:
            for source in (log, home / "protocol-fixture.log"):
                with source.open(errors="replace") as lines:
                    for line in lines:
                        LOG.info(
                            "service_output",
                            source=source.name,
                            line=ANSI_COLOUR.sub("", line).rstrip(),
                        )

            raise


def main() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Exercise LibreChat startup, bootstrap and restart"
    )
    parser.add_argument(
        "configuration", type=Path, help="generated service configuration JSON"
    )
    arguments = parser.parse_args(namespace=Arguments())

    try:
        configuration = StartupConfiguration.model_validate_json(
            arguments.configuration.read_text()
        )
        run(configuration)
    except KeyboardInterrupt:
        LOG.warning("startup_interrupted")
        return 130
    except Exception:
        LOG.exception("startup_failed")
        return 1

    LOG.info("startup_passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
