import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { PlanStore } from "./store.ts";
import { classifyShell, inspectionCommand } from "./shell.ts";

export const parentReaders = [
  "read",
  "grep",
  "find",
  "ls",
  "codemode",
  "ask_user",
  "planning_research",
  "submit_plan",
  "enter_plan_mode",
  "project_report",
  "symbol_search",
  "module_report",
  "read_symbol",
  "read_enclosing",
  "effective_config",
  "lens_diagnostics",
  "ast_grep_search",
  "ast_grep_outline",
  "web_search",
  "fetch_content",
  "get_search_content",
  "source_check",
];

function block(reason: string) {
  return { block: true as const, reason };
}

export async function planningPolicy(
  event: { toolName: string; input: Record<string, unknown> },
  ctx: Pick<ExtensionContext, "cwd" | "hasUI"> & {
    ui: Pick<ExtensionContext["ui"], "confirm">;
  },
  store: PlanStore,
  readOnlyTools: readonly string[],
  signal: AbortSignal,
): Promise<{ block: true; reason: string } | undefined> {
  if (signal.aborted) {
    return block("The planning operation was cancelled.");
  }
  if (event.toolName === "write" || event.toolName === "edit") {
    return typeof event.input.path === "string" &&
      store.permitsWrite(event.input.path, ctx.cwd)
      ? undefined
      : block(`Only the active plan may be edited: ${store.path}`);
  }
  if (event.toolName === "bash") {
    const command = event.input.command;
    if (typeof command !== "string") {
      return block("Pass a literal shell command.");
    }
    const decision = classifyShell(command);
    if (decision.kind === "mutation") {
      return block(
        `${decision.reason}. Keep implementation changes for after plan approval.`,
      );
    }
    if (decision.kind === "read-only") {
      event.input.command = inspectionCommand(command);
      return undefined;
    }
    if (!ctx.hasUI) {
      return block(
        `${decision.reason}. Use inspection tools or ask the user to run this investigation.`,
      );
    }
    const approved = await ctx.ui.confirm(
      "Allow this investigation command once?",
      `${command}\n\n${decision.reason}. This allows this command only; it does not approve the plan.`,
      { signal },
    );
    if (!approved || signal.aborted) {
      return block("The investigation command was not authorised.");
    }
    return undefined;
  }
  if (
    parentReaders.includes(event.toolName) ||
    readOnlyTools.includes(event.toolName)
  ) {
    return undefined;
  }
  return block(
    `${event.toolName} is unavailable during planning. Use read-only investigation tools and keep implementation for after plan approval.`,
  );
}
