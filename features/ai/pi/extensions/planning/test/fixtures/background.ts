import assert from "node:assert/strict";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  watch,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
} from "@earendil-works/pi-ai/compat";
import {
  getAgentDir,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";

export const backgroundModel: Model<"planning-background-fixture"> = {
  id: "fixture",
  name: "Fixture",
  api: "planning-background-fixture",
  provider: "planning-background-fixture",
  baseUrl: "http://127.0.0.1:1",
  reasoning: false,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 128000,
  maxTokens: 4096,
};

function waitForMarker(path: string, signal: AbortSignal): Promise<void> {
  signal.throwIfAborted();
  if (existsSync(path)) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const watcher = watch(dirname(path), () => {
      if (existsSync(path)) {
        finish();
      }
    });
    const timer = setTimeout(
      () => finish(new Error(`Fixture marker timed out: ${path}`)),
      60_000,
    );
    const cancel = () => finish(new Error("Fixture was cancelled."));
    const finish = (error?: Error) => {
      watcher.close();
      clearTimeout(timer);
      signal.removeEventListener("abort", cancel);
      if (error) {
        reject(error);
        return;
      }
      resolve();
    };
    signal.addEventListener("abort", cancel, { once: true });
    if (existsSync(path)) {
      finish();
    }
  });
}

export default function backgroundFixture(pi: ExtensionAPI): void {
  let calls = 0;
  const child = process.env.PI_SUBAGENT_RUNNER_PID === String(process.pid);
  pi.registerProvider(backgroundModel.provider, {
    apiKey: "fixture",
    api: backgroundModel.api,
    baseUrl: backgroundModel.baseUrl,
    models: [backgroundModel],
    streamSimple: (_model, context, options) => {
      const phase = calls++;
      const directory = getAgentDir();
      const trace = join(directory, "background-trace");
      const signal = options?.signal ?? AbortSignal.timeout(60_000);
      let content: AssistantMessage["content"];
      if (child) {
        content =
          phase === 0
            ? [
                {
                  type: "toolCall",
                  id: "child-mutation",
                  name: "bash",
                  arguments: { command: "printf changed > project.ts" },
                },
              ]
            : [{ type: "text", text: "Offline background child report." }];
      } else {
        const steps: Record<number, AssistantMessage["content"]> = {
          0: [
            {
              type: "toolCall",
              id: "explore",
              name: "subagent",
              arguments: {
                agent: "planning-explore",
                task: "Inspect the offline fixture.",
              },
            },
          ],
          1: [
            {
              type: "toolCall",
              id: "design",
              name: "subagent",
              arguments: {
                agent: "planning-plan",
                task: "Assess the offline fixture.",
              },
            },
          ],
          2: [
            {
              type: "toolCall",
              id: "approve",
              name: "submit_plan",
              arguments: {},
            },
          ],
          3: [
            {
              type: "toolCall",
              id: "parent-read",
              name: "read",
              arguments: { path: "project.ts" },
            },
          ],
        };
        content = steps[phase] ?? [
          { type: "text", text: "Parent fixture finished." },
        ];
      }
      const reason = content[0]?.type === "toolCall" ? "toolUse" : "stop";
      const message: AssistantMessage = {
        role: "assistant",
        content,
        api: backgroundModel.api,
        provider: backgroundModel.provider,
        model: backgroundModel.id,
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
      const finish = async () => {
        if (child && phase === 0) {
          appendFileSync(
            trace,
            `child-start:${options?.sessionId ?? "missing"}\n`,
          );
          const started = readFileSync(trace, "utf8")
            .split("\n")
            .filter((line) => line.startsWith("child-start:"));
          if (started.length === 2) {
            writeFileSync(join(directory, "two-ready"), "");
          }
          await waitForMarker(join(directory, "parent-work"), signal);
        }
        if (child && phase === 1) {
          const mutation = context.messages.findLast(
            (entry) =>
              entry.role === "toolResult" &&
              entry.toolCallId === "child-mutation",
          );
          assert.ok(mutation?.role === "toolResult");
          assert.equal(mutation.isError, true);
          appendFileSync(trace, "child-guarded\n");
        }
        if (!child && phase === 3) {
          const approval = context.messages.findLast(
            (entry) =>
              entry.role === "toolResult" && entry.toolCallId === "approve",
          );
          assert.ok(approval?.role === "toolResult");
          assert.equal(approval.isError, true);
          assert.ok(
            JSON.stringify(approval.content).includes(
              "A subagent is still active",
            ),
          );
          appendFileSync(trace, "approval-blocked\n");
        }
        if (!child && phase === 4) {
          const inspection = context.messages.findLast(
            (entry) =>
              entry.role === "toolResult" && entry.toolCallId === "parent-read",
          );
          assert.ok(inspection?.role === "toolResult");
          assert.equal(inspection.isError, false);
          await waitForMarker(join(directory, "two-ready"), signal);
          pi.events.emit("fixture:parent-ready", {});
          await waitForMarker(join(directory, "release"), signal);
          writeFileSync(join(directory, "parent-work"), "done");
        }
        if (!child && phase > 4) {
          appendFileSync(trace, "parent-wake\n");
        }
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason, message });
        stream.end();
      };
      queueMicrotask(() => {
        finish().catch((error: unknown) => {
          stream.push({
            type: "error",
            reason: "error",
            error: {
              ...message,
              stopReason: "error",
              errorMessage: String(error),
            },
          });
          stream.end();
        });
      });
      return stream;
    },
  });
}
