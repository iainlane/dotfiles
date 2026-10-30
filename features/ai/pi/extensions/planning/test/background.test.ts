import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Check } from "typebox/value";
import { Type } from "typebox";
import subagents from "pi-subagents";
import { resolveCurrentSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { expect, it, onTestFailed, vi } from "vitest";
import planning from "../src/extension.ts";
import { nodeFiles } from "../src/node-files.ts";
import { PlanStore } from "../src/store.ts";
import { ensureSubagentsIdle, planningAgents } from "../src/subagents.ts";
import backgroundFixture, { backgroundModel } from "./fixtures/background.ts";

const asyncResultSchema = Type.Object({ asyncId: Type.String() });

async function stopRuns(pi: ExtensionAPI, ids: Set<string>): Promise<void> {
  await Promise.all(
    [...ids].map(
      (id) =>
        new Promise<void>((resolve, reject) => {
          const requestId = randomUUID();
          const unsubscribe = pi.events.on(
            `subagents:rpc:v1:reply:${requestId}`,
            () => {
              clearTimeout(timer);
              unsubscribe();
              resolve();
            },
          );
          const timer = setTimeout(() => {
            unsubscribe();
            reject(new Error(`Native cleanup did not acknowledge run ${id}.`));
          }, 5000);
          pi.events.emit("subagents:rpc:v1:request", {
            version: 1,
            requestId,
            method: "stop",
            params: { id },
          });
        }),
    ),
  );
}

it("runs planning roles in the background while the parent investigates and leaves human-exited children read-only", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-planning-background-"));
  const agentDir = join(cwd, "agent");
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  const ready = Promise.withResolvers<void>();
  const completed = Promise.withResolvers<void>();
  const runIds = new Set<string>();
  let parentApi: ExtensionAPI | undefined;
  let session:
    | Awaited<ReturnType<typeof createAgentSession>>["session"]
    | undefined;
  let unsubscribe: (() => void) | undefined;
  let running: Promise<void> | undefined;
  onTestFailed(() => {
    const tracePath = join(agentDir, "background-trace");
    console.error("Native planning fixture diagnostics", {
      trace: existsSync(tracePath)
        ? readFileSync(tracePath, "utf8")
        : "missing",
      markers: ["two-ready", "release", "parent-work"].filter((marker) =>
        existsSync(join(agentDir, marker)),
      ),
      errors: session?.messages.filter(
        (message) =>
          message.role === "assistant" && message.stopReason === "error",
      ),
    });
  });
  try {
    await mkdir(agentDir, { recursive: true });
    await writeFile(join(cwd, "project.ts"), "original");
    await writeFile(
      join(agentDir, "planning.json"),
      JSON.stringify({
        readOnlyTools: [],
        researchExtensions: [
          fileURLToPath(new URL("./fixtures/background.ts", import.meta.url)),
        ],
      }),
    );
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false },
      retry: { enabled: false },
    });
    const loader = new DefaultResourceLoader({
      cwd,
      agentDir,
      settingsManager: settings,
      noExtensions: true,
      noSkills: true,
      noThemes: true,
      noPromptTemplates: true,
      noContextFiles: true,
      extensionFactories: [
        backgroundFixture,
        subagents,
        planning,
        (pi) => {
          parentApi = pi;
          pi.events.on("fixture:parent-ready", () => ready.resolve());
          pi.on("tool_result", (event) => {
            if (
              event.toolName === "subagent" &&
              Check(asyncResultSchema, event.details)
            ) {
              runIds.add(event.details.asyncId);
            }
          });
        },
      ],
    });
    await loader.reload();
    const runtime = await ModelRuntime.create({
      authPath: join(cwd, "auth.json"),
      modelsPath: join(cwd, "models.json"),
    });
    const manager = SessionManager.create(cwd, join(cwd, "sessions"));
    ({ session } = await createAgentSession({
      cwd,
      agentDir,
      resourceLoader: loader,
      modelRuntime: runtime,
      model: backgroundModel,
      thinkingLevel: "off",
      sessionManager: manager,
      settingsManager: settings,
      tools: [
        "read",
        "write",
        "bash",
        "subagent",
        "bg_wait",
        "subagents_enable",
        "enter_plan_mode",
        "submit_plan",
      ],
    }));
    await session.bindExtensions({});
    const active = session;
    const notifiedAgents = () => {
      const notices = active.messages.filter(
        (message) =>
          message.role === "custom" && message.customType === "subagent-notify",
      );
      return planningAgents.filter((agent) =>
        notices.some((notice) => JSON.stringify(notice).includes(agent)),
      );
    };
    const tracePath = join(agentDir, "background-trace");
    unsubscribe = session.subscribe((event) => {
      if (
        event.type === "agent_settled" &&
        notifiedAgents().length === 2 &&
        existsSync(tracePath) &&
        readFileSync(tracePath, "utf8").includes("parent-wake")
      ) {
        completed.resolve();
      }
    });
    await session.prompt("/plan");
    new PlanStore(
      join(agentDir, "plans"),
      manager.getSessionId(),
      nodeFiles,
    ).write("# Ready plan\n\nImplement the fixture.\n");
    running = session.prompt("Investigate with both planning roles.");
    await Promise.race([
      ready.promise,
      running.then(() => {
        throw new Error(
          `The parent finished before its independent investigation: ${JSON.stringify(active.messages.filter((message) => (message.role === "assistant" && message.stopReason === "error") || (message.role === "toolResult" && message.toolName === "subagent") || (message.role === "custom" && message.customType === "subagent-notify")))}`,
        );
      }),
    ]);
    await session.prompt("/plan");
    await writeFile(join(agentDir, "release"), "");
    await running;
    await completed.promise;
    if (!parentApi) {
      throw new Error("The native parent extension API was not registered.");
    }
    await ensureSubagentsIdle(parentApi.events, AbortSignal.timeout(10_000));
    const trace = (await readFile(tracePath, "utf8")).trim().split("\n");
    expect({
      started: trace.filter((line) => line.startsWith("child-start:")).length,
      guarded: trace.filter((line) => line === "child-guarded"),
      approvalBlocked: trace.includes("approval-blocked"),
      parentWoke: trace.includes("parent-wake"),
      notifiedAgents: notifiedAgents(),
      parentRestricted:
        resolveCurrentSubagentCapabilityCeiling(manager.getSessionId())
          ?.allowedAgents !== undefined,
      project: await readFile(join(cwd, "project.ts"), "utf8"),
      customResearchTool: parentApi
        .getAllTools()
        .some((tool) => tool.name === "planning_research"),
    }).toStrictEqual({
      started: 2,
      guarded: ["child-guarded", "child-guarded"],
      approvalBlocked: true,
      parentWoke: true,
      notifiedAgents: ["planning-explore", "planning-plan"],
      parentRestricted: false,
      project: "original",
      customResearchTool: false,
    });
  } finally {
    await writeFile(join(agentDir, "release"), "");
    await writeFile(join(agentDir, "parent-work"), "done");
    await session?.abort();
    await running;
    if (parentApi) {
      await stopRuns(parentApi, runIds);
    }
    unsubscribe?.();
    session?.dispose();
    vi.unstubAllEnvs();
    await rm(cwd, { recursive: true, force: true });
  }
}, 90_000);
