import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionFactory,
  type BoundaryResult,
} from "@earendil-works/pi-coding-agent";
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai";
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
import {
  attachedPlanContext,
  clearContextType,
  reminderType,
  implementationContext,
  implementationMessageType,
} from "../src/prompt.ts";
import { stateEntry } from "../src/session.ts";
import { PlanStore } from "../src/store.ts";
import { ensureSubagentsIdle } from "../src/subagents.ts";
import { feedbackImage } from "./fixtures/image.ts";
import { outcomeEntryType, outcomeSchema } from "../src/outcomes.ts";

const requestSchema = Type.Object({
  requestId: Type.String(),
  method: Type.Literal("status"),
});

const feedbackImageSchema = Type.Object({
  type: Type.Literal("image"),
  data: Type.Literal(feedbackImage.data),
  mimeType: Type.Literal(feedbackImage.mimeType),
});

interface ApprovalScenario {
  decision: "current" | "clear";
  outcome: "completed" | "aborted";
  imageFeedback: boolean;
  ordinaryCompaction: boolean;
  continuation?: "idle" | "busy" | "error";
  launchFailure?: boolean;
}

it.each<ApprovalScenario>([
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    launchFailure: true,
  },
  {
    decision: "current",
    outcome: "aborted",
    imageFeedback: false,
    ordinaryCompaction: false,
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
  },
  {
    decision: "clear",
    outcome: "aborted",
    imageFeedback: false,
    ordinaryCompaction: false,
  },
  {
    decision: "clear",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: true,
    ordinaryCompaction: false,
  },
  {
    decision: "clear",
    outcome: "completed",
    imageFeedback: true,
    ordinaryCompaction: false,
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: true,
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "idle",
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "busy",
  },
  {
    decision: "current",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "error",
  },
  {
    decision: "clear",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "idle",
  },
  {
    decision: "clear",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "busy",
  },
  {
    decision: "clear",
    outcome: "completed",
    imageFeedback: false,
    ordinaryCompaction: false,
    continuation: "error",
  },
])(
  "starts implementation only after verified $decision approval ($outcome, image feedback: $imageFeedback, ordinary compaction: $ordinaryCompaction, continuation: $continuation, launch failure: $launchFailure)",
  async ({
    decision,
    outcome,
    imageFeedback,
    ordinaryCompaction,
    continuation,
    launchFailure = false,
  }) => {
    const settledApproval =
      outcome === "completed" &&
      (continuation === undefined || continuation === "idle");
    const implementsPlan = settledApproval && !launchFailure;
    const cwd = await mkdtemp(join(tmpdir(), "pi-clear-cancellation-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const ready = Promise.withResolvers<void>();
    const sends =
      vi.fn<
        (
          content: Parameters<
            PlanningDependencies["sendImplementationMessage"]
          >[0],
        ) => void
      >();
    const starts: string[] = [];
    const errors: unknown[] = [];
    const ordinary: { reason: string; context: string | undefined }[] = [];
    const ordinarySummary =
      "No remediation implementation has begun. The user approved implementation and implementation is underway.";
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 8192 },
      retry: { enabled: false },
    });
    const requests: {
      planning: boolean;
      approvedBody: boolean;
      imageFeedback: boolean;
    }[] = [];
    const implementationPath = join(cwd, "implementation.txt");
    let releaseStatus: (() => void) | undefined;
    let checks = 0;
    let continued = false;
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
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    };
    const extension: ExtensionFactory = (pi) => {
      const planning = createPlanning({
        openPlan: (id) => new PlanStore(join(cwd, "plans"), id, nodeFiles),
        recordSavedState: (data) => pi.appendEntry(stateEntry, data),
        recordOutcome: (data) => pi.appendEntry(outcomeEntryType, data),
        presentPlan: () => {},
        configure: () => [],
        ensureSubagentsIdle: (signal) => ensureSubagentsIdle(pi.events, signal),
        startInPlan: () => true,
        requestId: () => "approval-fixture",
        sendUserMessage: (message, options) =>
          pi.sendUserMessage(message, options),
        sendImplementationMessage: (content, onError) => {
          sends(content);
          const options = { triggerTurn: true, onError };
          pi.sendMessage(
            { customType: implementationMessageType, content, display: false },
            options,
          );
        },
        review: async (_ctx, request) => ({
          decision,
          presentedPlan: request.plan,
          ...(imageFeedback ? { images: [feedbackImage] } : {}),
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
            data: {
              fleet: {
                totalActive: continued && continuation === "busy" ? 1 : 0,
              },
            },
          });
        if (++checks === 3) {
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
        streamSimple: (_model, context) => {
          const planningActive = getCurrentSystemPrompt(
            context.messages,
          ).includes("Plan mode is active.");
          requests.push({
            imageFeedback: context.messages.some((message) => {
              const content: unknown = message.content;
              return (
                Array.isArray(content) &&
                content.some((block: unknown) =>
                  Check(feedbackImageSchema, block),
                )
              );
            }),
            planning: planningActive,
            approvedBody: context.messages.some((message) =>
              JSON.stringify(message.content).includes(
                "# Approved fixture plan",
              ),
            ),
          });
          const lastUser = context.messages.findLastIndex(
            (message) => message.role === "user",
          );
          const written = context.messages
            .slice(lastUser + 1)
            .some(
              (message) =>
                message.role === "toolResult" && message.toolName === "write",
            );
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
              : planningActive
                ? [{ type: "text", text: "No implementation changes made." }]
                : written
                  ? [{ type: "text", text: "Implementation complete." }]
                  : [
                      {
                        type: "toolCall",
                        id: "implement",
                        name: "write",
                        arguments: {
                          path: implementationPath,
                          content:
                            ordinary.length > 0
                              ? "Continued approved implementation\n"
                              : "Approved implementation\n",
                        },
                      },
                    ];
          const failedContinuation =
            continued && planningActive && continuation === "error";
          const reason = failedContinuation
            ? "error"
            : content[0]?.type === "toolCall"
              ? "toolUse"
              : "stop";
          const message: AssistantMessage = {
            role: "assistant",
            content,
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: reason,
            ...(failedContinuation
              ? { errorMessage: "Fixture continued run failed" }
              : {}),
            timestamp: 1,
            usage: {
              input: ordinaryCompaction && written ? 127000 : 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: ordinaryCompaction && written ? 127000 : 0,
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
            if (reason === "error") {
              stream.push({ type: "error", reason, error: message });
            } else {
              stream.push({ type: "done", reason, message });
            }
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
          ).write(
            ordinaryCompaction
              ? "# Approved fixture plan\n\nThis revision requests new implementation approval.\n"
              : "# Approved fixture plan\n",
          );
          return planning.submit(ctx, signal);
        },
      });
      pi.on("session_start", (event, ctx) => planning.start(event, ctx));
      pi.on("before_agent_start", (event, ctx) => {
        starts.push(event.messageType);
        return planning.prompt(event, ctx);
      });
      pi.on("input", () => planning.input());
      pi.on("turn_end", (event, ctx) => planning.turnEnd(event, ctx));
      pi.on("agent_end", (_event, ctx) => {
        runSignal = ctx.signal;
        return planning.verifyClear(ctx);
      });
      pi.on("agent_before_settle", (event, ctx) =>
        planning.beforeSettle(event, ctx),
      );
      pi.on("agent_before_settle", (event): BoundaryResult | undefined => {
        if (continuation === undefined || continued) {
          return undefined;
        }
        continued = true;
        return {
          entries: [
            ...event.entries,
            {
              type: "custom_message",
              customType: "fixture-research-followup",
              content: "Continue planning with the research update.",
              display: false,
            },
          ],
          continue: true,
        };
      });
      pi.on("agent_settled", (event, ctx) => planning.settled(event, ctx));
      if (ordinaryCompaction) {
        pi.on("session_before_compact", (event) => ({
          compaction: {
            summary: ordinarySummary,
            firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore,
          },
        }));
        pi.on("session_compact", (event, ctx) => {
          const content = planning.compact(ctx);
          ordinary.push({ reason: event.reason, context: content });
          settings.setCompactionEnabled(false);
          if (content !== undefined) {
            pi.sendMessage(
              { customType: reminderType, content, display: false },
              { triggerTurn: false },
            );
          }
        });
      }
      pi.on("session_shutdown", () => planning.shutdown());
    };
    try {
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
      await session.bindExtensions({
        mode: "rpc",
        uiContext: {
          ...session.extensionRunner.getUIContext(),
          confirm: async (title) => title === "Enter Plan mode?",
        },
        onError: (error) => errors.push(error),
      });
      const nativeSend = session.sendCustomMessage.bind(session);
      let implementationAttempts = 0;
      vi.spyOn(session, "sendCustomMessage").mockImplementation(
        async (message, options) => {
          if (
            message.customType === implementationMessageType &&
            ++implementationAttempts === 2 &&
            launchFailure
          ) {
            throw new Error("Fixture deferred launch failed");
          }
          await nativeSend(message, options);
        },
      );
      let launchError: string | undefined;
      running = session
        .prompt("private-research-marker")
        .catch((error: unknown) => {
          launchError = String(error);
        });
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
      if (ordinaryCompaction) {
        settings.setCompactionEnabled(true);
        await session.prompt("Continue the approved implementation.");
      }
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
      const failureReason =
        outcome === "aborted"
          ? "Implementation approval was cancelled during research verification."
          : continuation === "busy"
            ? "Error: A subagent is still active. Wait for completion or cancel it before requesting implementation approval."
            : continuation === "error"
              ? "The planning run ended (error) before implementation started."
              : launchFailure
                ? "Error: Fixture deferred launch failed"
                : undefined;
      expect({
        launchError,
        attempts: implementationAttempts,
        failures: manager
          .getBranch()
          .flatMap((entry) =>
            entry.type === "custom" &&
            entry.customType === outcomeEntryType &&
            Check(outcomeSchema, entry.data) &&
            entry.data.event === "implementation-failed"
              ? [entry.data]
              : [],
          ),
        idleChecks: checks,
        ordinary,
        reviewOutcomes: manager
          .getBranch()
          .flatMap((entry) =>
            entry.type === "custom" &&
            entry.customType === outcomeEntryType &&
            Check(outcomeSchema, entry.data) &&
            entry.data.event === "review"
              ? [entry.data]
              : [],
          ),
        uiHistoryVisible: JSON.stringify(
          manager.buildSessionContext().messages,
        ).includes(outcomeEntryType),
        errors,
        compactions,
        sends: sends.mock.calls,
        runAborted: runSignal?.aborted,
        retainedResearch: JSON.stringify(
          manager.buildSessionContext().messages,
        ).includes("private-research-marker"),
        saved: saved?.type === "custom" ? saved.data : undefined,
        requests,
        starts,
        implementation: await readFile(implementationPath, "utf8").catch(
          (error: unknown) => {
            if (Check(Type.Object({ code: Type.Literal("ENOENT") }), error)) {
              return;
            }
            throw error;
          },
        ),
      }).toStrictEqual({
        launchError: launchFailure
          ? "Error: Fixture deferred launch failed"
          : undefined,
        attempts: settledApproval ? 2 : 0,
        failures:
          failureReason === undefined
            ? []
            : [
                {
                  version: 1,
                  event: "implementation-failed",
                  path: plan.path,
                  revision: plan.revision,
                  reason: failureReason,
                },
              ],
        idleChecks: continuation === undefined ? 3 : 4,
        ordinary: ordinaryCompaction
          ? [{ reason: "threshold", context: attachedPlanContext(plan) }]
          : [],
        reviewOutcomes: [
          {
            version: 1,
            event: "review",
            decision,
            path: plan.path,
            revision: plan.revision,
            ...(imageFeedback ? { images: [feedbackImage] } : {}),
          },
        ],
        uiHistoryVisible: false,
        errors: [],
        compactions: ordinaryCompaction
          ? [
              {
                summary: ordinarySummary,
                selfRetaining: false,
                details: undefined,
              },
            ]
          : outcome === "aborted" || decision === "current"
            ? []
            : Array.from({ length: continuation === "idle" ? 2 : 1 }, () => ({
                summary: implementationContext(plan, manager.getSessionId()),
                selfRetaining: true,
                details: {
                  customType: clearContextType,
                  token: "approval-fixture",
                },
              })),
        sends: settledApproval
          ? [
              [
                imageFeedback
                  ? [
                      {
                        type: "text",
                        text: implementationContext(
                          plan,
                          manager.getSessionId(),
                        ),
                      },
                      { type: "text", text: "User image feedback:" },
                      feedbackImage,
                    ]
                  : implementationContext(plan, manager.getSessionId()),
              ],
            ]
          : [],
        runAborted: outcome === "aborted",
        retainedResearch:
          !ordinaryCompaction &&
          (outcome === "aborted" || decision === "current"),
        requests: [
          { planning: true, approvedBody: false, imageFeedback: false },
          {
            planning: true,
            approvedBody: decision === "current",
            imageFeedback,
          },
          ...(continuation === undefined
            ? []
            : [{ planning: true, approvedBody: true, imageFeedback }]),
          ...(implementsPlan
            ? [
                { planning: false, approvedBody: true, imageFeedback },
                { planning: false, approvedBody: true, imageFeedback },
              ]
            : []),
          ...(ordinaryCompaction
            ? [
                { planning: false, approvedBody: true, imageFeedback: false },
                { planning: false, approvedBody: true, imageFeedback: false },
              ]
            : []),
        ],
        starts: implementsPlan
          ? ordinaryCompaction
            ? ["user", "custom", "user"]
            : ["user", "custom"]
          : ["user"],
        implementation: implementsPlan
          ? ordinaryCompaction
            ? "Continued approved implementation\n"
            : "Approved implementation\n"
          : undefined,
        saved: {
          version: 1,
          active: !settledApproval,
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
