import { join } from "node:path";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
} from "@earendil-works/pi-ai/compat";
import {
  getAgentDir,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { nodeFiles } from "#planning/node-files.ts";
import { PlanStore } from "#planning/store.ts";
import { DemoScenario } from "./scenario.ts";

export default function demoProvider(pi: ExtensionAPI): void {
  let scenario: DemoScenario | undefined;
  let sessionId: string | undefined;
  pi.on("session_start", (_event, ctx) => {
    sessionId = ctx.sessionManager.getSessionId();
    scenario = new DemoScenario(
      new PlanStore(join(getAgentDir(), "plans"), sessionId, nodeFiles).path,
    );
  });
  const model: Model<"planning-demo"> = {
    id: "scripted",
    name: "Offline demo (scripted)",
    api: "planning-demo",
    provider: "planning-demo",
    baseUrl: "http://127.0.0.1:1",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 4096,
  };
  pi.registerProvider(model.provider, {
    api: model.api,
    apiKey: "offline-demo",
    baseUrl: model.baseUrl,
    models: [model],
    streamSimple: (_model, context, options) => {
      if (!scenario || options?.sessionId !== sessionId) {
        throw new Error("The demo must remain in its original session.");
      }
      const content = scenario.next(context.messages);
      const reason = content.some((entry) => entry.type === "toolCall")
        ? "toolUse"
        : "stop";
      const message: AssistantMessage = {
        role: "assistant",
        content,
        api: model.api,
        provider: model.provider,
        model: model.id,
        stopReason: reason,
        timestamp: 1,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
      };
      const stream = createAssistantMessageEventStream();
      setTimeout(() => {
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason, message });
        stream.end();
      }, 450);
      return stream;
    },
  });
}
