import { nodeFiles } from "#planning/node-files.ts";
import { join } from "node:path";
import { fauxAssistantMessage, type Model } from "@earendil-works/pi-ai";
import {
  getAgentDir,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { PlanStore } from "#planning/store.ts";
import { boundaryText } from "./boundary.ts";
import {
  currentRun,
  lastToolResult,
  toolCallReply,
  transcriptProvider,
} from "./faux.ts";

const planningRequest =
  /Plan the fixed fixture|Review the boundary fixture|Exercise entry consent/;

const model: Model<"planning-rpc-fixture"> = {
  id: "fixture",
  name: "Fixture",
  api: "planning-rpc-fixture",
  provider: "planning-rpc-fixture",
  baseUrl: "http://127.0.0.1:1",
  reasoning: false,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  // The faux provider reports estimated token usage. Boundary-size plans
  // would otherwise fill the window and start an automatic compaction.
  contextWindow: 10_000_000,
  maxTokens: 4096,
};

export default function provider(pi: ExtensionAPI): void {
  let path = "";
  pi.on("session_start", (_event, ctx) => {
    path = new PlanStore(
      join(getAgentDir(), "plans"),
      ctx.sessionManager.getSessionId(),
      nodeFiles,
    ).path;
  });
  pi.on("session_before_compact", (event) => ({
    compaction: {
      summary: "Offline compaction fixture.",
      firstKeptEntryId: event.preparation.firstKeptEntryId,
      tokensBefore: event.preparation.tokensBefore,
    },
  }));
  const faux = transcriptProvider(model, (context) => {
    const { prompt, progress } = currentRun(context.messages);
    const last = lastToolResult(progress);
    if (prompt.includes("Implement this approved plan.")) {
      return fauxAssistantMessage(
        JSON.stringify(context.messages).includes("Plan mode is active.")
          ? "Implementation requested with planning instructions"
          : "Implementation fixture ready",
      );
    }
    if (prompt.includes("Probe restored") && last === undefined) {
      return toolCallReply("mutation", "write", {
        path: "project.ts",
        content: "unapproved",
      });
    }
    if (!planningRequest.test(prompt)) {
      return fauxAssistantMessage("Fixture finished");
    }
    const entry = progress.findLast(
      (message) =>
        message.role === "toolResult" && message.toolCallId === "enter",
    );
    if (last === undefined) {
      return toolCallReply("enter", "enter_plan_mode", {});
    }
    if (
      last === "enter" &&
      !JSON.stringify(entry?.content).includes("Plan mode was not entered")
    ) {
      return toolCallReply("draft", "write", {
        path,
        content:
          process.env.PI_PLANNING_BOUNDARY_KIND === undefined
            ? "# RPC plan\n\nImplement the reviewed fixture.\n"
            : boundaryText(
                "# Context\n\n",
                process.env.PI_PLANNING_BOUNDARY_KIND === "unicode"
                  ? "🦉"
                  : "\u0000",
              ),
      });
    }
    if (last === "draft") {
      return toolCallReply("submit", "submit_plan", {});
    }
    return fauxAssistantMessage("Fixture finished");
  });
  pi.registerProvider(faux.provider);
}
