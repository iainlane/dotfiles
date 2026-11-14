import assert from "node:assert/strict";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  watch,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fauxAssistantMessage, type Model } from "@earendil-works/pi-ai";
import {
  getAgentDir,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import {
  currentRun,
  lastToolResult,
  toolCallReply,
  transcriptProvider,
} from "./faux.ts";

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
    const cancel = () => finish(new Error("Fixture was cancelled."));
    const finish = (error?: Error) => {
      watcher.close();
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
  const child = process.env.PI_SUBAGENT_RUNNER_PID === String(process.pid);
  const faux = transcriptProvider(backgroundModel, async (context, options) => {
    const directory = getAgentDir();
    const trace = join(directory, "background-trace");
    const signal = options?.signal ?? new AbortController().signal;
    const result = (id: string) =>
      context.messages.findLast(
        (entry) => entry.role === "toolResult" && entry.toolCallId === id,
      );
    if (child) {
      if (lastToolResult(context.messages) === undefined) {
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
        return toolCallReply("child-mutation", "bash", {
          command: "printf changed > project.ts",
        });
      }
      const mutation = result("child-mutation");
      assert.ok(mutation?.role === "toolResult");
      assert.equal(mutation.isError, true);
      appendFileSync(trace, "child-guarded\n");
      return fauxAssistantMessage("Offline background child report.");
    }
    const { prompt, progress } = currentRun(context.messages);
    if (!prompt.includes("Investigate with both planning roles.")) {
      appendFileSync(trace, "parent-wake\n");
      return fauxAssistantMessage("Parent fixture finished.");
    }
    const last = lastToolResult(progress);
    if (last === undefined) {
      return toolCallReply("explore", "subagent", {
        agent: "planning-explore",
        task: "Inspect the offline fixture.",
      });
    }
    if (last === "explore") {
      return toolCallReply("design", "subagent", {
        agent: "planning-plan",
        task: "Assess the offline fixture.",
      });
    }
    if (last === "design") {
      return toolCallReply("approve", "submit_plan", {});
    }
    if (last === "approve") {
      const approval = result("approve");
      assert.ok(approval?.role === "toolResult");
      assert.equal(approval.isError, true);
      assert.ok(
        JSON.stringify(approval.content).includes("A subagent is still active"),
      );
      appendFileSync(trace, "approval-blocked\n");
      return toolCallReply("parent-read", "read", { path: "project.ts" });
    }
    const inspection = result("parent-read");
    assert.ok(inspection?.role === "toolResult");
    assert.equal(inspection.isError, false);
    await waitForMarker(join(directory, "two-ready"), signal);
    pi.events.emit("fixture:parent-ready", {});
    await waitForMarker(join(directory, "release"), signal);
    writeFileSync(join(directory, "parent-work"), "done");
    return fauxAssistantMessage("Parent fixture finished.");
  });
  pi.registerProvider(faux.provider);
}
