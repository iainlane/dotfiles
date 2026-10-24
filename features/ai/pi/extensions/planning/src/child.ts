import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyShell, inspectionCommand } from "./shell.ts";

export const researchTools = ["read", "grep", "find", "ls", "bash"];

export function childPolicy(event: {
  toolName: string;
  input: Record<string, unknown>;
}): { block: true; reason: string } | undefined {
  if (!researchTools.includes(event.toolName)) {
    return {
      block: true,
      reason:
        "Planning research permits file inspection and guarded shell only.",
    };
  }
  if (event.toolName !== "bash") {
    return undefined;
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
  pi.on("tool_call", childPolicy);
}
