import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
} from "@earendil-works/pi-ai/compat";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { expect, it, vi } from "vitest";
import {
  createPlanning,
  type PlanningDependencies,
} from "../src/controller.ts";
import { nodeFiles } from "../src/node-files.ts";
import { clearContextType, implementationContext } from "../src/prompt.ts";
import { stateEntry } from "../src/session.ts";
import { PlanStore } from "../src/store.ts";
import { ensureSubagentsIdle } from "../src/subagents.ts";

const requestSchema = Type.Object({
  requestId: Type.String(),
  method: Type.Literal("status"),
});

it.each(["aborted", "completed"] as const)(
  "clears native context only after uncancelled final verification (%s)",
  async (outcome) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-clear-cancellation-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const ready = Promise.withResolvers<void>();
    const sends = vi.fn<PlanningDependencies["sendUserMessage"]>();
    const errors: unknown[] = [];
    let releaseStatus: (() => void) | undefined;
    let checks = 0;
    let calls = 0;
    let runSignal: AbortSignal | undefined;
    let controller: ReturnType<typeof createPlanning> | undefined;
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
    let running: Promise<void> | undefined;
    const model: Model<"planning-clear-fixture"> = {
      id: "fixture",
      name: "Fixture",
      api: "planning-clear-fixture",
      provider: "planning-clear-fixture",
      baseUrl: "http://127.0.0.1:1",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    };
    const extension: ExtensionFactory = (pi) => {
      const planning = createPlanning({
        openPlan: (id) => new PlanStore(join(cwd, "plans"), id, nodeFiles),
        recordSavedState: (data) => pi.appendEntry(stateEntry, data),
        configure: () => [],
        readOnlyTools: () => [],
        ensureSubagentsIdle: (signal) => ensureSubagentsIdle(pi.events, signal),
        startInPlan: () => false,
        requestId: () => "approval-fixture",
        sendUserMessage: sends,
        review: async (_ctx, request) => ({
          decision: "clear",
          presentedPlan: request.plan,
        }),
      });
      controller = planning;
      pi.events.on("subagents:rpc:v1:request", (value: unknown) => {
        if (!Check(requestSchema, value)) {
          throw new Error("Expected a status request");
        }
        const reply = () =>
          pi.events.emit(`subagents:rpc:v1:reply:${value.requestId}`, {
            version: 1,
            requestId: value.requestId,
            success: true,
            data: { fleet: { totalActive: 0 } },
          });
        if (++checks === 2) {
          releaseStatus = reply;
          ready.resolve();
          return;
        }
        reply();
      });
      pi.registerProvider(model.provider, {
        apiKey: "fixture",
        api: model.api,
        baseUrl: model.baseUrl,
        models: [model],
        streamSimple: () => {
          const content: AssistantMessage["content"] =
            calls++ === 0
              ? [
                  {
                    type: "toolCall",
                    id: "approve",
                    name: "fixture_approval",
                    arguments: {},
                  },
                ]
              : [{ type: "text", text: "Planning finished." }];
          const reason = content[0]?.type === "toolCall" ? "toolUse" : "stop";
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
              cost: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0,
              },
            },
          };
          const stream = createAssistantMessageEventStream();
          queueMicrotask(() => {
            stream.push({ type: "start", partial: message });
            stream.push({ type: "done", reason, message });
            stream.end();
          });
          return stream;
        },
      });
      pi.registerTool({
        name: "fixture_approval",
        label: "Fixture approval",
        description: "Exercise offline plan approval",
        parameters: Type.Object({}),
        async execute(_id, _params, signal, _update, ctx) {
          await planning.enterTool(ctx, signal);
          new PlanStore(
            join(cwd, "plans"),
            ctx.sessionManager.getSessionId(),
            nodeFiles,
          ).write("# Approved fixture plan\n");
          return planning.submit(ctx, signal);
        },
      });
      pi.on("session_start", (event, ctx) => planning.start(event, ctx));
      pi.on("turn_end", (event, ctx) => planning.turnEnd(event, ctx));
      pi.on("agent_end", (_event, ctx) => {
        runSignal = ctx.signal;
        return planning.verifyClear(ctx);
      });
      pi.on("agent_before_settle", (event, ctx) =>
        planning.beforeSettle(event, ctx),
      );
      pi.on("agent_settled", (event, ctx) => planning.settled(event, ctx));
      pi.on("session_shutdown", () => planning.shutdown());
    };
    try {
      const settings = SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
      });
      const loader = new DefaultResourceLoader({
        cwd,
        agentDir: join(cwd, "agent"),
        settingsManager: settings,
        noExtensions: true,
        noSkills: true,
        noThemes: true,
        noPromptTemplates: true,
        noContextFiles: true,
        extensionFactories: [extension],
      });
      await loader.reload();
      const runtime = await ModelRuntime.create({
        authPath: join(cwd, "auth.json"),
        modelsPath: join(cwd, "models.json"),
      });
      ({ session } = await createAgentSession({
        cwd,
        agentDir: join(cwd, "agent"),
        resourceLoader: loader,
        modelRuntime: runtime,
        model,
        thinkingLevel: "off",
        sessionManager: SessionManager.inMemory(cwd),
        settingsManager: settings,
      }));
      await session.bindExtensions({ onError: (error) => errors.push(error) });
      running = session.prompt("private-research-marker");
      await Promise.race([
        ready.promise,
        running.then(() => {
          throw new Error("The run ended before status verification paused");
        }),
      ]);
      if (!releaseStatus) {
        throw new Error("Expected a delayed status response");
      }
      const aborting =
        outcome === "aborted" ? session.abort() : Promise.resolve();
      releaseStatus();
      await Promise.all([running, aborting]);
      const manager = session.sessionManager;
      const plan = new PlanStore(
        join(cwd, "plans"),
        manager.getSessionId(),
        nodeFiles,
      ).read();
      const compactions = manager.getBranch().flatMap((entry) =>
        entry.type === "compaction"
          ? [
              {
                summary: entry.summary,
                selfRetaining: entry.firstKeptEntryId === entry.id,
                details: entry.details,
              },
            ]
          : [],
      );
      const saved = manager
        .getBranch()
        .findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        );
      expect({
        errors,
        compactions,
        sends: sends.mock.calls,
        runAborted: runSignal?.aborted,
        retainedResearch: JSON.stringify(
          manager.buildSessionContext().messages,
        ).includes("private-research-marker"),
        saved: saved?.type === "custom" ? saved.data : undefined,
      }).toStrictEqual({
        errors: [],
        compactions:
          outcome === "aborted"
            ? []
            : [
                {
                  summary: implementationContext(plan, manager.getSessionId()),
                  selfRetaining: true,
                  details: {
                    customType: clearContextType,
                    token: "approval-fixture",
                  },
                },
              ],
        sends:
          outcome === "aborted"
            ? []
            : [
                [
                  `Implement the approved plan at ${plan.path} (approved revision ${plan.revision}).`,
                  { expandPromptTemplates: false },
                ],
              ],
        runAborted: outcome === "aborted",
        retainedResearch: outcome === "aborted",
        saved: {
          version: 1,
          active: outcome === "aborted",
          sourceSessionId: manager.getSessionId(),
          exitReminderPending: false,
        },
      });
    } finally {
      releaseStatus?.();
      await running;
      await session?.abort();
      session?.dispose();
      controller?.shutdown();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
  20_000,
);
