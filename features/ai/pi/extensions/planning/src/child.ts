import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { researchPolicy, type PlanningToolCall } from "./policy.ts";
import { registerPlanningRoles } from "./roles.ts";
import { readPlanningSettings } from "./settings.ts";
import { classifyShell, inspectionCommand } from "./shell.ts";

export function childPolicy(
  event: PlanningToolCall,
  readOnlyTools: readonly string[] = [],
): { block: true; reason: string } | undefined {
  if (
    ["write", "edit", "ask_user", "submit_plan", "enter_plan_mode"].includes(
      event.toolName,
    )
  ) {
    return {
      block: true,
      reason:
        "Research agents cannot edit files, ask the user or approve implementation.",
    };
  }
  if (event.toolName !== "bash") {
    return researchPolicy(event, readOnlyTools);
  }
  const command = event.input.command;
  if (typeof command !== "string") {
    return { block: true, reason: "Pass a literal shell command." };
  }
  const decision = classifyShell(command);
  if (decision.kind !== "read-only") {
    return {
      block: true,
      reason: `${decision.reason}. Return the required investigation to the parent.`,
    };
  }
  event.input.command = inspectionCommand(command);
  return undefined;
}

export default function planningChild(pi: ExtensionAPI): void {
  let registrations: ReturnType<typeof registerPlanningRoles> = [];
  pi.on("tool_call", (event) => {
    try {
      return childPolicy(event, readPlanningSettings().readOnlyTools);
    } catch (error) {
      return {
        block: true,
        reason: `Planning settings are unavailable: ${String(error)}`,
      };
    }
  });
  pi.on("session_start", () => {
    registrations = registerPlanningRoles(pi, readPlanningSettings());
  });
  pi.on("session_shutdown", () => {
    for (const registration of registrations.splice(0)) {
      registration.dispose();
    }
  });
}
