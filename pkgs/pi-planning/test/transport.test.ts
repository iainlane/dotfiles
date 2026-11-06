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
  streamSimple as streamNative,
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
import {
  emptyPlanInputSchema,
  submitPlanOutputSchema,
} from "../src/contracts.ts";
import { nodeFiles } from "../src/node-files.ts";
import { outcomeEntryType } from "../src/outcomes.ts";
import { stateEntry } from "../src/session.ts";
import { PlanStore } from "../src/store.ts";
import { maxPlanCodeUnits } from "../src/validation.ts";
import { feedbackImage } from "./fixtures/image.ts";

const stringSchema = Type.String();
const arraySchema = Type.Array(Type.Unknown());
const objectSchema = Type.Record(Type.String(), Type.Unknown());

function stringValues(value: unknown): string[] {
  if (Check(stringSchema, value)) {
    return [value];
  }
  if (Check(arraySchema, value)) {
    return value.flatMap((item) => stringValues(item));
  }
  if (Check(objectSchema, value)) {
    return Object.values(value).flatMap((item) => stringValues(item));
  }
  return [];
}

function atLimit(prefix: string, character: string): string {
  const available = maxPlanCodeUnits - prefix.length;
  return (
    prefix +
    character.repeat(Math.floor(available / character.length)) +
    "x".repeat(available % character.length)
  );
}

const apis = [
  "anthropic-messages",
  "openai-responses",
  "openai-completions",
  "google-generative-ai",
] as const;
it.each(
  apis.flatMap((api) => [
    { api, character: "a", kind: "ASCII" },
    { api, character: "\u0000", kind: "JSON escapes" },
    { api, character: "🦉", kind: "UTF-8" },
  ]),
)(
  "serialises complete boundary-size $kind plans, feedback and native images through $api HTTP clients",
  async ({ api, character }) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-plan-transport-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const captured: Buffer[] = [];
    const capture: typeof globalThis.fetch = async (input, init) => {
      const request = new Request(input, init);
      if (new URL(request.url).hostname !== "127.0.0.1") {
        throw new Error("The transport fixture permits only loopback requests");
      }
      captured.push(Buffer.from(await request.arrayBuffer()));
      return new Response(
        JSON.stringify({
          error: { type: "fixture", message: "Fixture capture complete" },
        }),
        { status: 400, headers: { "content-type": "application/json" } },
      );
    };
    vi.stubGlobal("fetch", capture);
    const feedback = atLimit("Keep this interface.\n", character);
    const content = atLimit("# Context\n\nRequested work.\n", character);
    const sends =
      vi.fn<
        (
          content: Parameters<
            PlanningDependencies["sendImplementationMessage"]
          >[0],
        ) => void
      >();
    const model: Model<"planning-transport-fixture"> = {
      id: "fixture",
      name: "Fixture",
      api: "planning-transport-fixture",
      provider: "planning-transport-fixture",
      baseUrl: "http://127.0.0.1:1",
      reasoning: false,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 1_000_000,
      maxTokens: 16,
    };
    let calls = 0;
    const extension: ExtensionFactory = (pi) => {
      const controller = createPlanning({
        openPlan: (id) => new PlanStore(join(cwd, "plans"), id, nodeFiles),
        presentPlan: () => {},
        recordSavedState: (state) => pi.appendEntry(stateEntry, state),
        recordOutcome: (outcome) => pi.appendEntry(outcomeEntryType, outcome),
        configure: () => [],
        ensureSubagentsIdle: async () => {},
        startInPlan: () => true,
        setReviewAvailable: () => {},
        sendUserMessage: () => {},
        sendImplementationMessage: (message) => sends(message),
        requestId: () => "transport-fixture",
        review: async (_ctx, request) => ({
          decision: "current",
          presentedPlan: request.plan,
          feedback,
          images: [feedbackImage],
        }),
      });
      pi.registerTool({
        name: "submit_plan",
        label: "Review plan",
        description: "Offline review fixture",
        parameters: emptyPlanInputSchema,
        outputSchema: submitPlanOutputSchema,
        execute: (_id, _args, signal, update, ctx) =>
          controller.submit(ctx, signal, update),
      });
      pi.on("session_start", (event, ctx) => controller.start(event, ctx));
      pi.on("before_agent_start", (event, ctx) =>
        controller.prompt(event, ctx),
      );
      pi.on("agent_end", (_event, ctx) => controller.verifyClear(ctx));
      pi.on("agent_before_settle", (event, ctx) =>
        controller.beforeSettle(event, ctx),
      );
      pi.on("agent_settled", (event, ctx) => controller.settled(event, ctx));
      pi.on("session_shutdown", () => controller.shutdown());
      pi.registerProvider(model.provider, {
        apiKey: "fixture",
        api: model.api,
        baseUrl: model.baseUrl,
        models: [model],
        streamSimple: (_model, context, options) => {
          if (calls++ > 0) {
            return streamNative(
              {
                ...model,
                api,
                provider:
                  api === "anthropic-messages"
                    ? "anthropic"
                    : api === "google-generative-ai"
                      ? "google"
                      : "openai",
              },
              context,
              {
                apiKey: "fixture",
                fetch: capture,
                maxRetries: 0,
                signal: options?.signal,
              },
            );
          }
          const stream = createAssistantMessageEventStream();
          const message = {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "review",
                name: "submit_plan",
                arguments: {},
              },
            ],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: "toolUse",
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
          } satisfies AssistantMessage;
          queueMicrotask(() => {
            stream.push({ type: "done", reason: "toolUse", message });
            stream.end();
          });
          return stream;
        },
      });
    };
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
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
        sessionManager: SessionManager.create(cwd, join(cwd, "sessions")),
        settingsManager: settings,
      }));
      const plan = new PlanStore(
        join(cwd, "plans"),
        session.sessionManager.getSessionId(),
        nodeFiles,
      ).write(content);
      await session.bindExtensions({});
      await session.prompt("Review the offline fixture plan.");
      const requests = captured.map((bytes) => {
        const text = bytes.toString("utf8");
        const payload: unknown = JSON.parse(text);
        const strings = stringValues(payload);
        const includes = (expected: string) =>
          strings.some(
            (value) =>
              value.includes(expected) ||
              value.includes(JSON.stringify(expected).slice(1, -1)),
          );
        return {
          completeUtf8: bytes.equals(Buffer.from(text, "utf8")),
          plan: includes(content),
          feedback: includes(feedback),
          path: includes(plan.path),
          revision: includes(plan.revision),
          image: includes(feedbackImage.data),
          mime: includes(feedbackImage.mimeType),
        };
      });
      expect({
        codeUnits: [content.length, feedback.length],
        requests,
        implementation: sends.mock.calls,
      }).toStrictEqual({
        codeUnits: [maxPlanCodeUnits, maxPlanCodeUnits],
        requests: [
          {
            completeUtf8: true,
            plan: true,
            feedback: true,
            path: true,
            revision: true,
            image: true,
            mime: true,
          },
        ],
        implementation: [],
      });
    } finally {
      await session?.abort();
      session?.dispose();
      vi.unstubAllGlobals();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
