# Planning exploration

`plan_explore({ task })` launches a background codebase research agent. The
findings arrive through pi-subagents' normal completion notification.

The extension registers `plan-explorer` through the public runtime-agent API.
Only model settings can override a runtime agent's definition. The agent has
`read`, `grep`, `find` and `ls`, with no shell, writing tools, extensions, MCP
or nested delegation. Each launch also applies a capability ceiling. The child
captures that ceiling before the launch acknowledgement releases the parent's
registration. The RPC cannot cancel an unacknowledged launch. If the caller
cancels, the tool waits for the receipt and requests that the returned run stop
before releasing the ceiling.

The tool accepts only a research task. It fixes the working directory to the
parent's directory, uses fresh context, disables worktrees and does not accept
an output path. pi-subagents still writes its own session and lifecycle files;
this is a tool-capability restriction, not an OS sandbox.

Plan mode permits this tool explicitly. The general `subagent` tool remains
outside the default Plan allowlist because it also supports management,
workflows and host commands. Normal-mode subagent configuration is unchanged.

The integration uses the public [runtime-agent registration] and [capability
ceiling] APIs. It does not inspect Plan mode's internal session entries.

[runtime-agent registration]:
  https://github.com/nicobailon/pi-subagents/blob/main/docs/extension-api.md#runtime-agent-registration-from-independent-extensions
[capability ceiling]:
  https://github.com/nicobailon/pi-subagents/blob/main/docs/extension-api.md#capability-ceilings

## Development

```sh
npm ci
npm run check
```
