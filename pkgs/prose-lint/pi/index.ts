// Runs prose-lint's Claude Code hooks from pi. Each pi event is sent to
// `prose-lint hook` as the Claude Code payload for the same moment, and the
// hook's response is applied through pi's extension results.

import { spawn } from "node:child_process";
import { resolve } from "node:path";

// Pi's SDK types are unavailable in this standalone extension.
interface Context {
  cwd: string;
  sessionManager: { getSessionId(): string };
  ui: { notify(message: string, type?: "info" | "warning" | "error"): void };
}

interface TextContent {
  type: "text";
  text: string;
}

interface ToolCallEvent {
  toolName: string;
  input: Record<string, unknown>;
}

interface ToolResultEvent extends ToolCallEvent {
  content: unknown[];
  isError: boolean;
}

interface SettleEvent {
  outcome: "completed" | "aborted" | "error";
}

interface ExtensionAPI {
  on(
    event: "tool_call",
    handler: (
      event: ToolCallEvent,
      ctx: Context,
    ) => Promise<{ block: true; reason: string } | undefined>,
  ): unknown;
  on(
    event: "tool_result",
    handler: (
      event: ToolResultEvent,
      ctx: Context,
    ) => Promise<{ content: unknown[] } | undefined>,
  ): unknown;
  on(
    event: "agent_before_settle",
    handler: (
      event: SettleEvent,
      ctx: Context,
    ) => Promise<
      | {
          continue: true;
          entries: {
            type: "custom_message";
            customType: string;
            content: string;
            display: boolean;
          }[];
        }
      | undefined
    >,
  ): unknown;
}

type HookEvent = "pre-tool-use" | "post-tool-use" | "stop";

interface HookResponse {
  decision?: "block";
  reason?: string;
  systemMessage?: string;
  hookSpecificOutput?: {
    permissionDecision?: "deny";
    permissionDecisionReason?: string;
    additionalContext?: string;
  };
}

const PROSE_LINT = "@proseLint@";
const CUSTOM_TYPE = "prose-lint";
const TIMEOUT_MILLISECONDS = 30_000;
const EDIT_TOOLS: Record<string, string> = { edit: "Edit", write: "Write" };

// Claude Code's names for the pi tools that prose-lint handles.
function claudeTool(event: ToolCallEvent, cwd: string) {
  if (event.toolName === "bash" && typeof event.input.command === "string") {
    return { tool_name: "Bash", tool_input: { command: event.input.command } };
  }

  const name = EDIT_TOOLS[event.toolName];
  if (name === undefined || typeof event.input.path !== "string") return null;

  return {
    tool_name: name,
    tool_input: { file_path: resolve(cwd, event.input.path) },
  };
}

// Runs one hook. The hook always exits 0 and prints nothing when it has
// nothing to report, so a missing or unparsable response means no findings.
// `pi.exec` cannot write to the child's standard input, which the hook reads.
function runHook(
  event: HookEvent,
  payload: { cwd: string } & Record<string, unknown>,
): Promise<HookResponse | null> {
  return new Promise((done) => {
    const child = spawn(PROSE_LINT, ["hook", event], {
      cwd: payload.cwd,
      stdio: ["pipe", "pipe", "inherit"],
      timeout: TIMEOUT_MILLISECONDS,
    });
    let output = "";

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      output += chunk;
    });
    child.on("error", () => done(null));
    child.on("close", () => {
      if (output.trim() === "") return done(null);

      try {
        done(JSON.parse(output) as HookResponse);
      } catch {
        done(null);
      }
    });

    child.stdin.end(JSON.stringify(payload));
  });
}

function session(ctx: Context) {
  return { session_id: ctx.sessionManager.getSessionId(), cwd: ctx.cwd };
}

function notify(ctx: Context, response: HookResponse | null) {
  if (response?.systemMessage) ctx.ui.notify(response.systemMessage, "warning");
}

export default function (pi: ExtensionAPI) {
  // Sessions in which this extension continued the last settle. Claude Code
  // passes the same fact to its Stop hook as `stop_hook_active`.
  const continued = new Set<string>();

  pi.on("tool_call", async (event, ctx) => {
    const tool = claudeTool(event, ctx.cwd);
    if (tool === null) return undefined;

    const response = await runHook("pre-tool-use", {
      ...session(ctx),
      ...tool,
    });
    notify(ctx, response);

    const specific = response?.hookSpecificOutput;
    if (specific?.additionalContext) {
      ctx.ui.notify(specific.additionalContext, "warning");
    }

    if (specific?.permissionDecision !== "deny") return undefined;

    return { block: true, reason: specific.permissionDecisionReason ?? "" };
  });

  pi.on("tool_result", async (event, ctx) => {
    if (event.isError || EDIT_TOOLS[event.toolName] === undefined) {
      return undefined;
    }

    const tool = claudeTool(event, ctx.cwd);
    if (tool === null) return undefined;

    const response = await runHook("post-tool-use", {
      ...session(ctx),
      ...tool,
    });
    notify(ctx, response);

    const feedback = [
      response?.reason,
      response?.hookSpecificOutput?.additionalContext,
    ].filter((text): text is string => Boolean(text));

    if (feedback.length === 0) return undefined;

    const added: TextContent[] = feedback.map((text) => ({
      type: "text",
      text,
    }));

    return { content: [...event.content, ...added] };
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    const id = ctx.sessionManager.getSessionId();
    const active = continued.delete(id);

    if (event.outcome !== "completed") return undefined;

    const response = await runHook("stop", {
      ...session(ctx),
      stop_hook_active: active,
    });
    notify(ctx, response);

    if (response?.decision !== "block") return undefined;

    continued.add(id);

    return {
      continue: true,
      entries: [
        {
          type: "custom_message",
          customType: CUSTOM_TYPE,
          content: response.reason ?? "",
          display: true,
        },
      ],
    };
  });
}
