import { nodeFiles } from "../../src/node-files.ts";
import { appendFileSync } from "node:fs";
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
import { PlanStore } from "../../src/store.ts";

export default function provider(pi: ExtensionAPI): void {
  let calls = 0;
  let reason = "startup";
  let path = "";
  pi.on("session_start", (event, ctx) => {
    reason = event.reason;
    path = new PlanStore(
      join(getAgentDir(), "plans"),
      ctx.sessionManager.getSessionId(),
      nodeFiles,
    ).path;
    if (
      process.env.PI_PLANNING_TRACE !== undefined &&
      process.env.PI_PLANNING_TRACE !== ""
    ) {
      appendFileSync(
        process.env.PI_PLANNING_TRACE,
        JSON.stringify({
          reason,
          path,
          id: ctx.sessionManager.getSessionId(),
          file: ctx.sessionManager.getSessionFile(),
        }) + "\n",
      );
    }
  });
  pi.on("session_before_compact", (event) => ({
    compaction: {
      summary: "Offline compaction fixture.",
      firstKeptEntryId: event.preparation.firstKeptEntryId,
      tokensBefore: event.preparation.tokensBefore,
    },
  }));
  const model: Model<"planning-rpc-fixture"> = {
    id: "fixture",
    name: "Fixture",
    api: "planning-rpc-fixture",
    provider: "planning-rpc-fixture",
    baseUrl: "http://127.0.0.1:1",
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 4096,
  };
  pi.registerProvider(model.provider, {
    apiKey: "fixture",
    api: model.api,
    baseUrl: model.baseUrl,
    models: [model],
    streamSimple: (_model, context) => {
      const step = calls++;
      const trace = process.env.PI_PLANNING_REQUEST_TRACE;
      if (trace !== undefined && trace !== "") {
        appendFileSync(trace, JSON.stringify({ step, context }) + "\n");
      }
      const workflow =
        process.env.PI_PLANNING_RESUME_PROBE === "1" ? "resume" : reason;
      const content: AssistantMessage["content"] =
        workflow === "startup" && step === 0
          ? [
              {
                type: "toolCall",
                id: "enter",
                name: "enter_plan_mode",
                arguments: {},
              },
            ]
          : workflow === "startup" && step === 1
            ? [
                {
                  type: "toolCall",
                  id: "draft",
                  name: "write",
                  arguments: {
                    path,
                    content: "# RPC plan\n\nImplement the reviewed fixture.\n",
                  },
                },
              ]
            : workflow === "startup" && step === 2
              ? [
                  {
                    type: "toolCall",
                    id: "submit",
                    name: "submit_plan",
                    arguments: {},
                  },
                ]
              : workflow === "resume" && step === 0
                ? [
                    {
                      type: "toolCall",
                      id: "mutation",
                      name: "write",
                      arguments: { path: "project.ts", content: "unapproved" },
                    },
                  ]
                : [
                    {
                      type: "text",
                      text:
                        workflow === "startup" && step >= 4
                          ? "Implementation fixture ready"
                          : "Fixture finished",
                    },
                  ];
      const stopReason = content[0]?.type === "toolCall" ? "toolUse" : "stop";
      const message: AssistantMessage = {
        role: "assistant",
        content,
        api: model.api,
        provider: model.provider,
        model: model.id,
        stopReason,
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
      queueMicrotask(() => {
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason: stopReason, message });
        stream.end();
      });
      return stream;
    },
  });
}
