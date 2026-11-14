import {
  createMcpExtension,
  createToolSearchExtension,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { researchPolicy } from "./policy.ts";
import { registerPlanningRoles } from "./roles.ts";
import { readPlanningSettings } from "./settings.ts";

export default async function planningChild(pi: ExtensionAPI): Promise<void> {
  await createToolSearchExtension()(pi);
  await createMcpExtension()(pi);
  let registrations: ReturnType<typeof registerPlanningRoles> = [];
  pi.on("tool_call", (event) => researchPolicy(event));
  pi.on("session_start", () => {
    registrations = registerPlanningRoles(pi, readPlanningSettings());
  });
  pi.on("session_shutdown", () => {
    for (const registration of registrations.splice(0)) {
      registration.dispose();
    }
  });
}
