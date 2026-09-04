"""Typed subset of the Codex app-server configuration protocol."""

from typing import Literal

import msgspec


class CodexRpcError(msgspec.Struct, frozen=True):
    """A JSON-RPC error returned by Codex app-server."""

    code: int


class CodexRpcEnvelope(msgspec.Struct, frozen=True):
    """Fields needed to route one app-server response or notification."""

    id: int | None = None
    method: str | None = None
    error: CodexRpcError | None = None


class CodexExternalLoginParameters(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    tag="chatgptAuthTokens",
    tag_field="type",
):
    """Externally managed ChatGPT access accepted by app-server."""

    access_token: str
    chatgpt_account_id: str
    chatgpt_plan_type: str | None


class CodexExternalLoginResult(
    msgspec.Struct,
    frozen=True,
    tag="chatgptAuthTokens",
    tag_field="type",
):
    """Confirmation that app-server installed external ChatGPT auth."""


class CodexExternalLoginResponse(msgspec.Struct, frozen=True):
    """Response to an external ChatGPT authentication request."""

    id: int
    result: CodexExternalLoginResult | None = None


class CodexThreadReference(msgspec.Struct, frozen=True):
    """Identity of a newly started app-server thread."""

    id: str


class CodexThreadStartResult(msgspec.Struct, frozen=True):
    """Thread fields needed to begin the first model turn."""

    thread: CodexThreadReference


class CodexThreadStartResponse(msgspec.Struct, frozen=True):
    """Response to `thread/start`."""

    id: int
    result: CodexThreadStartResult | None = None


class CodexTurnReference(msgspec.Struct, frozen=True):
    """Identity of a newly started model turn."""

    id: str


class CodexTurnStartResult(msgspec.Struct, frozen=True):
    """Turn fields returned when model execution begins."""

    turn: CodexTurnReference


class CodexTurnStartResponse(msgspec.Struct, frozen=True):
    """Response to `turn/start`."""

    id: int
    result: CodexTurnStartResult | None = None


class CodexItemHeader(msgspec.Struct, frozen=True):
    """Discriminator shared by every completed app-server item."""

    type: str


class CodexAgentMessageItem(
    msgspec.Struct,
    frozen=True,
    tag="agentMessage",
    tag_field="type",
):
    """Completed assistant message emitted by app-server."""

    id: str
    text: str


class CodexItemCompletedParameters(
    msgspec.Struct,
    frozen=True,
    rename="camel",
):
    """Completed item notification with deferred item decoding."""

    item: msgspec.Raw
    thread_id: str
    turn_id: str


class CodexItemCompletedNotification(msgspec.Struct, frozen=True):
    """Envelope for an `item/completed` notification."""

    method: Literal["item/completed"]
    params: CodexItemCompletedParameters


class CodexTurnFailure(msgspec.Struct, frozen=True, rename="camel"):
    """Failure details attached to a terminal app-server turn."""

    message: str
    codex_error_info: msgspec.Raw | None = None


class CodexCompletedTurn(msgspec.Struct, frozen=True):
    """Terminal state included in `turn/completed`."""

    id: str
    status: Literal["completed", "interrupted", "failed"]
    error: CodexTurnFailure | None


class CodexTurnCompletedParameters(
    msgspec.Struct,
    frozen=True,
    rename="camel",
):
    """Terminal turn notification parameters."""

    thread_id: str
    turn: CodexCompletedTurn


class CodexTurnCompletedNotification(msgspec.Struct, frozen=True):
    """Envelope for a `turn/completed` notification."""

    method: Literal["turn/completed"]
    params: CodexTurnCompletedParameters


class CodexInitializeResult(
    msgspec.Struct,
    frozen=True,
    rename="camel",
    forbid_unknown_fields=True,
):
    """Runtime identity returned by app-server initialization."""

    user_agent: str
    codex_home: str
    platform_family: str
    platform_os: str


class CodexInitializeResponse(msgspec.Struct, frozen=True):
    """A successful app-server initialization response."""

    id: int
    result: CodexInitializeResult | None = None


class CodexEffectiveConfiguration(msgspec.Struct, frozen=True):
    """Isolation-sensitive values returned by `config/read`."""

    mcp_servers: dict[str, msgspec.Raw]
    features: dict[str, "CodexFeatureValue"]
    project_root_markers: tuple[str, ...]
    project_doc_max_bytes: int
    default_permissions: str
    permissions: dict[str, msgspec.Raw]
    web_search: str | None
    notify: tuple[str, ...] | None
    instructions: str | None
    developer_instructions: str | None
    model_instructions_file: str | None
    personality: str | None
    agents: "CodexAgentsConfiguration"
    skills: "CodexSkillsConfiguration"
    model_provider: str | None
    openai_base_url: str | None
    chatgpt_base_url: str | None
    service_tier: str | None
    model_verbosity: Literal["low", "medium", "high"] | None
    model_context_window: int | None
    compact_prompt: str | None
    model_auto_compact_token_limit: int | None
    model_auto_compact_token_limit_scope: Literal["total", "body_after_prefix"] | None


class CodexAgentsConfiguration(
    msgspec.Struct,
    frozen=True,
    forbid_unknown_fields=True,
):
    """Every multi-agent setting returned by effective configuration."""

    enabled: bool | None = None
    max_concurrent_threads_per_session: int | None = None
    max_depth: int | None = None
    default_subagent_model: str | None = None
    default_subagent_reasoning_effort: str | None = None
    job_max_runtime_seconds: int | None = None
    interrupt_message: bool | None = None


type CodexFeatureValue = bool | dict[str, object] | None


class CodexSkillConfiguration(msgspec.Struct, frozen=True, forbid_unknown_fields=True):
    """One path- or name-selected skill entry returned by effective config."""

    enabled: bool
    path: str | None = None
    name: str | None = None


class CodexBundledSkillsConfiguration(
    msgspec.Struct,
    frozen=True,
    forbid_unknown_fields=True,
):
    """Whether Codex may install and load its bundled skills."""

    enabled: bool


class CodexSkillsConfiguration(
    msgspec.Struct,
    frozen=True,
    forbid_unknown_fields=True,
):
    """Every skill-loading control returned by effective configuration."""

    bundled: CodexBundledSkillsConfiguration | None = None
    include_instructions: bool | None = None
    config: tuple[CodexSkillConfiguration, ...] = ()


class CodexNetworkPermissions(msgspec.Struct, frozen=True, forbid_unknown_fields=True):
    """Every network control accepted by an effective permission profile."""

    enabled: bool | None = None
    proxy_url: str | None = None
    enable_socks5: bool | None = None
    socks_url: str | None = None
    enable_socks5_udp: bool | None = None
    allow_upstream_proxy: bool | None = None
    dangerously_allow_non_loopback_proxy: bool | None = None
    dangerously_allow_all_unix_sockets: bool | None = None
    mode: str | None = None
    domains: dict[str, str] | None = None
    unix_sockets: dict[str, str] | None = None
    allow_local_binding: bool | None = None
    mitm: msgspec.Raw | None = None


type CodexFilesystemPermission = (
    Literal["read", "write", "deny"]
    | dict[str, Literal["read", "write", "deny"]]
    | int
    | None
)


class CodexPermissionProfile(msgspec.Struct, frozen=True, forbid_unknown_fields=True):
    """Isolation-sensitive fields of the selected judge permission profile."""

    filesystem: dict[str, CodexFilesystemPermission]
    network: CodexNetworkPermissions
    description: str | None = None
    extends: str | None = None
    workspace_roots: dict[str, bool] | None = None


class CodexPromptIsolation(msgspec.Struct, frozen=True):
    """Prompt-bearing settings which must be neutral in an isolated judge."""

    notify: tuple[str, ...] | None
    instructions: str | None
    developer_instructions: str | None
    model_instructions_file: str | None
    personality: str | None


class CodexModelTransport(msgspec.Struct, frozen=True):
    """Provider and endpoints used for judge model traffic."""

    provider: str | None
    openai_base_url: str | None
    chatgpt_base_url: str | None


class CodexCompactionConfiguration(msgspec.Struct, frozen=True):
    """Prompt and thresholds which can change model-visible compaction."""

    prompt: str | None
    token_limit: int | None
    token_limit_scope: Literal["total", "body_after_prefix"] | None


class CodexModelRequestConfiguration(msgspec.Struct, frozen=True):
    """Model request controls which must not be inherited from the host."""

    service_tier: str | None
    verbosity: Literal["low", "medium", "high"] | None
    context_window: int | None


class CodexConfigReadResult(msgspec.Struct, frozen=True):
    """The runtime-effective portion of a `config/read` response."""

    config: CodexEffectiveConfiguration


class CodexConfigReadResponse(msgspec.Struct, frozen=True):
    """A successful effective-configuration response."""

    id: int
    result: CodexConfigReadResult | None = None


class CodexRequirementsReadResult(msgspec.Struct, frozen=True):
    """Presence of runtime requirements which may constrain MCP servers."""

    requirements: dict[str, msgspec.Raw] | None


class CodexRequirementsReadResponse(msgspec.Struct, frozen=True):
    """A successful managed-requirements response."""

    id: int
    result: CodexRequirementsReadResult | None = None


class CodexMcpEnabledState(msgspec.Struct, frozen=True):
    """The launch state common to every effective MCP transport."""

    enabled: bool


class CodexMcpEnvironmentVariable(msgspec.Struct, frozen=True):
    """A named environment variable resolved for a stdio MCP server."""

    name: str
    source: Literal["local", "remote"] | None = None


class CodexMcpOAuthConfiguration(msgspec.Struct, frozen=True):
    """OAuth client settings for an HTTP MCP server."""

    client_id: str | None = None


class CodexMcpToolConfiguration(msgspec.Struct, frozen=True):
    """Approval policy for one MCP tool."""

    approval_mode: Literal["auto", "prompt", "writes", "approve"] | None = None


class CodexEffectiveMcpServer(msgspec.Struct, frozen=True, forbid_unknown_fields=True):
    """Every launch-affecting field accepted for one effective MCP server."""

    command: str | None = None
    args: tuple[str, ...] = ()
    env: dict[str, str] | None = None
    env_vars: tuple[str | CodexMcpEnvironmentVariable, ...] = ()
    cwd: str | None = None
    http_headers: dict[str, str] | None = None
    env_http_headers: dict[str, str] | None = None
    url: str | None = None
    bearer_token_env_var: str | None = None
    auth: Literal["oauth", "chatgpt"] | None = None
    environment_id: str = "local"
    enabled: bool = True
    required: bool = False
    supports_parallel_tool_calls: bool = False
    startup_timeout_sec: float | None = None
    tool_timeout_sec: float | None = None
    default_tools_approval_mode: (
        Literal["auto", "prompt", "writes", "approve"] | None
    ) = None
    enabled_tools: tuple[str, ...] | None = None
    disabled_tools: tuple[str, ...] | None = None
    scopes: tuple[str, ...] | None = None
    oauth: CodexMcpOAuthConfiguration | None = None
    oauth_resource: str | None = None
    tools: dict[str, CodexMcpToolConfiguration] = msgspec.field(default_factory=dict)
