import {
  createMcpExtension,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { researchPolicy, type PlanningToolCall } from "./policy.ts";
import { registerPlanningRoles } from "./roles.ts";
import { readPlanningSettings } from "./settings.ts";

export function childPolicy(
  event: PlanningToolCall,
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
  return researchPolicy(event);
}

export default async function planningChild(pi: ExtensionAPI): Promise<void> {
  await createMcpExtension()(pi);
  let registrations: ReturnType<typeof registerPlanningRoles> = [];
  pi.on("tool_call", (event) => childPolicy(event));
  pi.on("session_start", () => {
    registrations = registerPlanningRoles(pi, readPlanningSettings());
  });
  pi.on("session_shutdown", () => {
    for (const registration of registrations.splice(0)) {
      registration.dispose();
    }
  });
}
