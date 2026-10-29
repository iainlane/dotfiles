import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { researchPolicy, type PlanningToolCall } from "./policy.ts";
import { registerPlanningRoles } from "./roles.ts";
import { readPlanningSettings } from "./settings.ts";
import { classifyShell, inspectionCommand } from "./shell.ts";

const delegationSchema = Type.Object(
  {
    agent: Type.Union([
      Type.Literal("planning-explore"),
      Type.Literal("planning-plan"),
    ]),
    task: Type.String({ minLength: 1 }),
    model: Type.Optional(Type.String()),
    cwd: Type.Optional(Type.String()),
    async: Type.Optional(Type.Literal(false)),
    output: Type.Optional(Type.Literal(false)),
    options: Type.Optional(
      Type.Object(
        {
          context: Type.Optional(Type.Literal("fresh")),
          artifacts: Type.Optional(Type.Literal(false)),
          mission: Type.Optional(Type.Literal(false)),
          timeoutMs: Type.Optional(Type.Integer({ minimum: 1 })),
        },
        { additionalProperties: false },
      ),
    ),
  },
  { additionalProperties: false },
);

export function childPolicy(
  event: PlanningToolCall,
  readOnlyTools: readonly string[] = [],
): { block: true; reason: string } | undefined {
  if (event.toolName === "subagent") {
    if (!Check(delegationSchema, event.input)) {
      return {
        block: true,
        reason:
          "Delegate a focused task to planning-explore or planning-plan with async:false. Workflows, output files and implementation agents are unavailable during planning.",
      };
    }
    event.input.async = false;
    event.input.output = false;
    event.input.options = {
      ...event.input.options,
      context: "fresh",
      artifacts: false,
      mission: false,
    };
    return undefined;
  }
  if (
    [
      "write",
      "edit",
      "ask_user",
      "submit_plan",
      "enter_plan_mode",
      "planning_research",
    ].includes(event.toolName)
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
