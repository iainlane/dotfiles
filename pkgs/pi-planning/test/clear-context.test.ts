import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
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
  type SessionEntry,
} from "@earendil-works/pi-coding-agent";
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
} from "@earendil-works/pi-ai/compat";
import { Type } from "typebox";
import { Check } from "typebox/value";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { expect, it, vi } from "vitest";
import { createPlanning } from "#planning/controller.ts";
import { nodeFiles } from "#planning/node-files.ts";
import {
  attachedPlanContext,
  clearContextType,
  reminderType,
  implementationContext,
  implementationMessageType,
  reviewedPlanContext,
} from "#planning/prompt.ts";
import { stateEntry } from "#planning/session.ts";
import { PlanStore } from "#planning/store.ts";
import { ensureSubagentsIdle } from "#planning/subagents.ts";
import { feedbackImage } from "./fixtures/image.ts";
import { outcomeEntryType } from "#planning/outcomes.ts";

const resumePrompt = "Continue the approved implementation.";

const outcomeEventSchema = Type.Object({ event: Type.String() });

const requestSchema = Type.Object({
  requestId: Type.String(),
  method: Type.Literal("status"),
});

async function readOptionalFile(path: string): Promise<string | undefined> {
  let contents: string | undefined;
  try {
    contents = await readFile(path, "utf8");
  } catch (error) {
    if (!Check(Type.Object({ code: Type.Literal("ENOENT") }), error)) {
      throw error;
    }
  }
  return contents;
}

/** Summarises a message that the model sees or that a session records. */
function steps(message: AgentMessage): unknown[] {
  if (message.role === "user") {
    return [{ user: message.content }];
  }

  if (message.role === "assistant") {
    return [
      {
        assistant: message.content,
        stopReason: message.stopReason,
        ...(message.errorMessage === undefined
          ? {}
          : { errorMessage: message.errorMessage }),
      },
    ];
  }

  if (message.role === "toolResult") {
    return [
      {
        result: message.toolCallId,
        isError: message.isError,
        content: message.content,
      },
    ];
  }

  if (message.role === "custom") {
    return [{ custom: message.customType, content: message.content }];
  }

  if (message.role === "compactionSummary") {
    return [{ compaction: message.summary }];
  }

  return [];
}

/**
 * Summarises the messages, custom messages and compactions on a session
 * branch.
 */
function transcript(entries: SessionEntry[]): unknown[] {
  return entries.flatMap((entry) => {
    if (entry.type === "compaction") {
      return [
        {
          compaction: entry.summary,
          selfRetaining: entry.firstKeptEntryId === entry.id,
          details: entry.details,
        },
      ];
    }

    if (entry.type === "custom_message") {
      return [{ custom: entry.customType, content: entry.content }];
    }

    return entry.type === "message" ? steps(entry.message) : [];
  });
}

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
    const cwd = await realpath(
      await mkdtemp(join(tmpdir(), "pi-clear-cancellation-")),
    );
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const ready = Promise.withResolvers<void>();
    const errors: unknown[] = [];
    const notifications: { message: string; level: string | undefined }[] = [];
    const ordinarySummary =
      "No remediation implementation has begun. The user approved implementation and implementation is underway.";
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 8192 },
      retry: { enabled: false },
    });
    const implementationPath = join(cwd, "implementation.txt");
    let releaseStatus: (() => void) | undefined;
    let verifying = false;
    let continued = false;
    let runSignal: AbortSignal | undefined;
    let controller: ReturnType<typeof createPlanning> | undefined;
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
    let running: Promise<unknown> | undefined;
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
        setReviewAvailable: () => {},
        requestId: () => "approval-fixture",
        sendUserMessage: (message, options) =>
          pi.sendUserMessage(message, options),
        sendImplementationMessage: (content, onError) => {
          if (launchFailure) {
            onError(new Error("Fixture deferred launch failed"));
            return;
          }
          pi.sendMessage(
            { customType: implementationMessageType, content, display: false },
            { triggerTurn: true, onError },
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
        if (verifying && releaseStatus === undefined) {
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
          const lastUser = context.messages.findLastIndex(
            (message) => message.role === "user",
          );
          const since = context.messages.slice(lastUser + 1);
          const written = since.some(
            (message) =>
              message.role === "toolResult" && message.toolName === "write",
          );
          const researchRequest =
            JSON.stringify(context.messages[lastUser]?.content).includes(
              "private-research-marker",
            ) &&
            !since.some(
              (message) =>
                message.role === "toolResult" &&
                message.toolName === "fixture_approval",
            );
          const content: AssistantMessage["content"] = researchRequest
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
                        content: JSON.stringify(
                          context.messages[lastUser]?.content,
                        ).includes(resumePrompt)
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
      pi.on("before_agent_start", (event, ctx) => planning.prompt(event, ctx));
      pi.on("input", () => planning.input());
      pi.on("turn_end", (event, ctx) => planning.turnEnd(event, ctx));
      pi.on("agent_end", async (_event, ctx) => {
        runSignal = ctx.signal;
        verifying = true;
        try {
          await planning.verifyClear(ctx);
        } finally {
          verifying = false;
        }
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
        pi.on("session_compact", (_event, ctx) => {
          const content = planning.compact(ctx);
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
          notify: (message, level) => notifications.push({ message, level }),
        },
        onError: (error) => errors.push(error),
      });
      running = session.prompt("private-research-marker");
      await Promise.race([
        ready.promise,
        (async () => {
          await running;
          throw new Error("The run ended before status verification paused");
        })(),
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
        await session.prompt(resumePrompt);
      }
      const saved = manager
        .getBranch()
        .findLast(
          (entry) => entry.type === "custom" && entry.customType === stateEntry,
        );
      const failureReason =
        outcome === "aborted"
          ? "Implementation approval was cancelled during research verification."
          : continuation === "busy"
            ? "A subagent is still active. Wait for completion or cancel it before requesting implementation approval."
            : continuation === "error"
              ? "The planning run ended (error) before implementation started."
              : launchFailure
                ? "Fixture deferred launch failed"
                : undefined;
      const context = implementationContext(plan, manager.getSessionId());
      const imageBlocks = imageFeedback
        ? [{ type: "text", text: "User image feedback:" }, feedbackImage]
        : [];
      const planningReply = {
        assistant: [{ type: "text", text: "No implementation changes made." }],
        stopReason: "stop",
      };
      const completed = {
        assistant: [{ type: "text", text: "Implementation complete." }],
        stopReason: "stop",
      };
      const implementationRun = (content: string) => [
        {
          assistant: [
            {
              type: "toolCall",
              id: "implement",
              name: "write",
              arguments: { path: implementationPath, content },
            },
          ],
          stopReason: "toolUse",
        },
        {
          result: "implement",
          isError: false,
          content: [
            {
              type: "text",
              text: `Successfully wrote to ${implementationPath}`,
            },
          ],
        },
        completed,
      ];
      const planningRun = [
        { user: [{ type: "text", text: "private-research-marker" }] },
        {
          assistant: [
            {
              type: "toolCall",
              id: "approve",
              name: "fixture_approval",
              arguments: {},
            },
          ],
          stopReason: "toolUse",
        },
        {
          result: "approve",
          isError: false,
          content: [
            ...(decision === "current"
              ? [
                  {
                    type: "text",
                    text: "Plan approved. Finish this planning turn and wait for the implementation transition; do not edit project files yet.",
                  },
                  { type: "text", text: reviewedPlanContext(plan) },
                ]
              : [
                  {
                    type: "text",
                    text: "Plan approved. Wait for context clearing; keep this conversation in planning until the transition finishes.",
                  },
                ]),
            ...imageBlocks,
          ],
        },
        planningReply,
      ];
      const continuedRun =
        continuation === undefined
          ? []
          : [
              {
                custom: "fixture-research-followup",
                content: "Continue planning with the research update.",
              },
              continuation === "error"
                ? {
                    ...planningReply,
                    stopReason: "error",
                    errorMessage: "Fixture continued run failed",
                  }
                : planningReply,
            ];
      const approvedRun = implementsPlan
        ? [
            {
              custom: implementationMessageType,
              content: imageFeedback
                ? [{ type: "text", text: context }, ...imageBlocks]
                : context,
            },
            ...implementationRun("Approved implementation\n"),
          ]
        : [];
      const resumedRun = [
        { custom: reminderType, content: attachedPlanContext(plan) },
        { user: [{ type: "text", text: resumePrompt }] },
        ...implementationRun("Continued approved implementation\n"),
      ];
      const cleared = decision === "clear" && outcome === "completed";
      const clearing = cleared
        ? [
            {
              compaction: context,
              selfRetaining: true,
              details: {
                customType: clearContextType,
                token: "approval-fixture",
              },
            },
          ]
        : [];
      // Each run after a clearing approval starts from a compaction that
      // keeps only its own summary, so the model sees only the latest run.
      const latestRun = approvedRun.length > 0 ? approvedRun : continuedRun;
      expect({
        failures: manager
          .getBranch()
          .flatMap((entry) =>
            entry.type === "custom" &&
            entry.customType === outcomeEntryType &&
            Check(outcomeEventSchema, entry.data) &&
            entry.data.event === "implementation-failed"
              ? [entry.data]
              : [],
          ),
        reviewOutcomes: manager
          .getBranch()
          .flatMap((entry) =>
            entry.type === "custom" &&
            entry.customType === outcomeEntryType &&
            Check(outcomeEventSchema, entry.data) &&
            entry.data.event === "review"
              ? [entry.data]
              : [],
          ),
        errors,
        notifications,
        transcript: transcript(manager.getBranch()),
        modelContext: manager
          .buildSessionContext()
          .messages.flatMap((message) => steps(message)),
        runAborted: runSignal?.aborted,
        saved: saved?.type === "custom" ? saved.data : undefined,
        implementation: await readOptionalFile(implementationPath),
      }).toStrictEqual({
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
        errors: [],
        notifications: launchFailure
          ? [
              {
                message: "Fixture deferred launch failed",
                level: "error",
              },
            ]
          : continuation === "busy"
            ? [
                {
                  message: `Cannot start approved implementation: ${failureReason}`,
                  level: "error",
                },
              ]
            : [],
        transcript: [
          ...planningRun,
          ...(continuedRun.length > 0 ? [...clearing, ...continuedRun] : []),
          ...(approvedRun.length > 0 ? [...clearing, ...approvedRun] : []),
          ...(ordinaryCompaction
            ? [
                {
                  compaction: ordinarySummary,
                  selfRetaining: false,
                  details: undefined,
                },
                ...resumedRun,
              ]
            : []),
        ],
        modelContext: ordinaryCompaction
          ? [{ compaction: ordinarySummary }, completed, ...resumedRun]
          : cleared
            ? [{ compaction: context }, ...latestRun]
            : [...planningRun, ...continuedRun, ...approvedRun],
        runAborted: outcome === "aborted",
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
);
