import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createPiPrClient } from "pi-prs/api";
import { createFooter } from "./controller.ts";
import { nodeRuntime } from "./node-runtime.ts";

export default function sessionFooter(pi: ExtensionAPI): void {
  const footer = createFooter({
    events: pi.events,
    runtime: nodeRuntime,
    subscribePr: (callback) => createPiPrClient(pi).onState(callback),
  });
  pi.registerCommand("footer", {
    description:
      "Inspect footer measurements, workflow state and integration details",
    handler: (args, ctx) => footer.inspect(args, ctx),
  });
  pi.on("session_start", (_event, ctx) => footer.start(ctx));
  pi.on("session_shutdown", () => footer.shutdown());
  pi.on("session_tree", (_event, ctx) => footer.selectBranch(ctx));
  pi.on("message_end", (event, ctx) =>
    footer.endMessage(
      ctx,
      event.message.role === "assistant" &&
        event.message.stopReason === "error",
    ),
  );
  pi.on("model_select", (_event, ctx) => footer.selectModel(ctx));
  pi.on("thinking_level_select", (_event, ctx) => footer.selectThinking(ctx));
  pi.on("agent_start", (_event, ctx) => footer.startAgent(ctx));
  pi.on("agent_settled", (event, ctx) =>
    footer.settleAgent(ctx, event.aborted),
  );
  pi.on("message_update", () => footer.updateMessage());
  pi.on("ui_prompt_start", () => footer.startPrompt());
  pi.on("ui_prompt_end", () => footer.endPrompt());
  pi.on("session_before_compact", () => footer.startCompaction());
  pi.on("session_compact", (_event, ctx) => footer.finishCompaction(ctx));
  pi.on("session_compact_failed", () => footer.failCompaction());
  pi.on("tool_execution_start", (event) =>
    footer.startTool(event.toolCallId, event.toolName),
  );
  pi.on("tool_execution_end", (event) => footer.endTool(event.toolCallId));
}
