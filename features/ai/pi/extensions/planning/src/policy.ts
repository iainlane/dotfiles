import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import type { PlanStore } from "./store.ts";
import { classifyShell, inspectionCommand } from "./shell.ts";
import { subagentPolicy } from "./subagents.ts";

export const researchReaders = [
  "read",
  "grep",
  "find",
  "ls",
  "codemode",
  "todo",
  "bg_wait",
  "web_enable",
  "pi_lens_activate_tools",
  "lsp_navigation",
  "ast_grep_replace",
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

export const researchTools = [...researchReaders, "bash", "subagent"];

const navigationOperations = Type.Union(
  [
    "definition",
    "typeDefinition",
    "declaration",
    "references",
    "hover",
    "signatureHelp",
    "documentSymbol",
    "findSymbol",
    "workspaceSymbol",
    "codeAction",
    "rename",
    "rename_file",
    "implementation",
    "prepareCallHierarchy",
    "incomingCalls",
    "outgoingCalls",
    "executeCommand",
    "workspaceDiagnostics",
    "capabilities",
  ].map((operation) => Type.Literal(operation)),
);

export interface PlanningToolCall {
  toolName: string;
  input: Record<string, unknown>;
}

function block(reason: string) {
  return { block: true as const, reason };
}

export function researchPolicy(
  event: PlanningToolCall,
  readOnlyTools: readonly string[],
): { block: true; reason: string } | undefined {
  if (event.toolName === "subagent") {
    return subagentPolicy(event);
  }
  if (
    event.toolName === "lsp_navigation" &&
    !Check(navigationOperations, event.input.operation)
  ) {
    return block(
      "Use a recognised read-only LSP operation or an edit preview.",
    );
  }
  if (
    (event.toolName === "lsp_navigation" ||
      event.toolName === "ast_grep_replace") &&
    event.input.apply !== undefined &&
    event.input.apply !== false
  ) {
    return block("Only previews are available before plan approval.");
  }
  if (
    researchReaders.includes(event.toolName) ||
    readOnlyTools.includes(event.toolName)
  ) {
    return undefined;
  }
  return block(
    `${event.toolName} is unavailable during planning. Use read-only investigation tools and keep implementation for after plan approval.`,
  );
}

export async function planningPolicy(
  event: PlanningToolCall,
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
    ["ask_user", "subagents_enable", "submit_plan", "enter_plan_mode"].includes(
      event.toolName,
    )
  ) {
    return undefined;
  }
  return researchPolicy(event, readOnlyTools);
}
