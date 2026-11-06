import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import type { PlanStore } from "./store.ts";
import { subagentPolicy } from "./subagents.ts";

export const mcpResourceReaders = [
  "list_mcp_resources",
  "list_mcp_resource_templates",
  "read_mcp_resource",
];

export const researchReaders = [
  "read",
  "grep",
  "find",
  "ls",
  "codemode",
  "contact_supervisor",
  "tool_search",
  ...mcpResourceReaders,
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

function usesNativePolicy(toolName: string): boolean {
  return toolName === "bash" || toolName.startsWith("mcp__");
}

export function researchPolicy(
  event: PlanningToolCall,
): { block: true; reason: string } | undefined {
  if (usesNativePolicy(event.toolName)) {
    return undefined;
  }
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
  if (researchReaders.includes(event.toolName)) {
    return undefined;
  }
  return block(
    `${event.toolName} is unavailable during planning. Use read-only investigation tools and keep implementation for after plan approval.`,
  );
}

export async function planningPolicy(
  event: PlanningToolCall,
  ctx: Pick<ExtensionContext, "cwd">,
  store: PlanStore,
  signal: AbortSignal,
): Promise<{ block: true; reason: string } | undefined> {
  if (usesNativePolicy(event.toolName)) {
    return undefined;
  }
  if (signal.aborted) {
    return block("The planning operation was cancelled.");
  }
  if (event.toolName === "write" || event.toolName === "edit") {
    return typeof event.input.path === "string" &&
      store.permitsWrite(event.input.path, ctx.cwd)
      ? undefined
      : block(`Only the active plan may be edited: ${store.path}`);
  }
  if (
    ["ask_user", "subagents_enable", "submit_plan", "enter_plan_mode"].includes(
      event.toolName,
    )
  ) {
    return undefined;
  }
  return researchPolicy(event);
}
