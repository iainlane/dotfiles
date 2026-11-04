import type {
  ExtensionAPI,
  ToolCallEventResult,
} from "@earendil-works/pi-coding-agent";

export default function nativePermissionsFixture(pi: ExtensionAPI): void {
  pi.on("tool_call", (event): ToolCallEventResult | undefined => {
    if (
      (event.toolName === "bash" &&
        event.input.command === "printf changed > project.ts") ||
      event.toolName === "mcp__fixture__mutate_tool"
    ) {
      return {
        block: true,
        reason: `Native permission fixture refused ${JSON.stringify(event.input)}`,
      };
    }
    return undefined;
  });
}
