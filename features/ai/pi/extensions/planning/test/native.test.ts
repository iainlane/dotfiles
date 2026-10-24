import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
} from "@earendil-works/pi-ai/compat";
import {
  createAgentSession,
  createCodemodeExtension,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import subagents from "pi-subagents";
import { getCurrentTools } from "@earendil-works/pi-ai";
import { resolveCurrentSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { resolvePiLaunchToolPlan } from "pi-subagents/child-tool-plan";
import { expect, it, vi } from "vitest";
import planning from "../src/extension.ts";

it.each([
  {
    command: "review",
    message:
      "Review the active plan, resolve any remaining questions, and call submit_plan.",
  },
  {
    command: "Investigate the new task",
    message: "Plan this task: Investigate the new task",
  },
])(
  "queues /plan $command while the native agent is streaming",
  async ({ command, message }) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-planning-busy-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const ready = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const model: Model<"planning-busy-fixture"> = {
      id: "fixture",
      name: "Fixture",
      api: "planning-busy-fixture",
      provider: "planning-busy-fixture",
      baseUrl: "http://127.0.0.1:1",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    };
    let calls = 0;
    const provider: ExtensionFactory = (pi) => {
      pi.registerProvider(model.provider, {
        apiKey: "fixture",
        api: model.api,
        baseUrl: model.baseUrl,
        models: [model],
        streamSimple: () => {
          const first = calls++ === 0;
          const assistant: AssistantMessage = {
            role: "assistant",
            content: [{ type: "text", text: "Fixture finished" }],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: "stop",
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
          const finish = () => {
            stream.push({ type: "done", reason: "stop", message: assistant });
            stream.end();
          };
          queueMicrotask(() => {
            stream.push({ type: "start", partial: assistant });
            if (!first) {
              finish();
              return;
            }
            ready.resolve();
            release.promise.then(finish).catch((error: unknown) => {
              stream.push({
                type: "error",
                reason: "error",
                error: {
                  ...assistant,
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
    };
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
    let running: Promise<void> | undefined;
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
        extensionFactories: [provider, subagents, planning],
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
        sessionManager: SessionManager.create(cwd, join(cwd, "sessions")),
        settingsManager: settings,
      }));
      const activeSession = session;
      const errors: unknown[] = [];
      await session.bindExtensions({ onError: (error) => errors.push(error) });
      if (command === "review") {
        await session.prompt("/plan");
      }
      running = session.prompt("Investigate slowly");
      await ready.promise;
      await session.prompt(`/plan ${command}`);
      await expect
        .poll(() => activeSession.getSteeringMessages())
        .toStrictEqual([message]);
      expect(errors).toStrictEqual([]);
      release.resolve();
      await running;
      expect(
        session.messages
          .filter((entry) => entry.role === "user")
          .map((entry) => entry.content),
      ).toStrictEqual([
        [{ type: "text", text: "Investigate slowly" }],
        [{ type: "text", text: message }],
      ]);
      expect({
        errors,
        pending: session.pendingMessageCount,
        streaming: session.isStreaming,
      }).toStrictEqual({
        errors: [],
        pending: 0,
        streaming: false,
      });
    } finally {
      release.resolve();
      await running;
      await session?.abort();
      session?.dispose();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
);

it.each([
  {
    mode: "codemode",
    expected: {
      childCancelled: false,
      sessions: ["parent", "parent"],
      childSessionCount: 0,
      childTools: [],
      blocked: [],
    },
  },
  {
    mode: "research",
    expected: {
      childCancelled: false,
      sessions: ["parent", "parent", "child", "child", "parent"],
      childSessionCount: 1,
      childTools: [
        ["bash", "find", "grep", "ls", "read"],
        ["bash", "find", "grep", "ls", "read"],
      ],
      blocked: [false, true],
    },
  },
  {
    mode: "research-cancel",
    expected: {
      childCancelled: true,
      sessions: ["parent", "parent", "child"],
      childSessionCount: 1,
      childTools: [["bash", "find", "grep", "ls", "read"]],
      blocked: [false],
    },
  },
])(
  "runs $mode through native planning and resolves a guarded child launch",
  async ({ mode, expected }) => {
    const cwd = await mkdtemp(join(tmpdir(), "pi-planning-native-"));
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const model: Model<"planning-fixture"> = {
      id: "fixture",
      name: "Fixture",
      api: "planning-fixture",
      provider: "planning-fixture",
      baseUrl: "http://127.0.0.1:1",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 4096,
    };
    let calls = 0;
    let childCancelled = false;
    const childStarted = Promise.withResolvers<void>();
    const requests: {
      sessionId: string | undefined;
      tools: string[];
      guardBlocked: boolean;
    }[] = [];
    const provider: ExtensionFactory = (pi) => {
      pi.registerProvider(model.provider, {
        apiKey: "fixture",
        api: model.api,
        baseUrl: model.baseUrl,
        models: [model],
        streamSimple: (_model, context, options) => {
          requests.push({
            sessionId: options?.sessionId,
            tools: getCurrentTools(context.messages)
              .map((tool) => tool.name)
              .toSorted(),
            guardBlocked: context.messages.some(
              (message) =>
                message.role === "toolResult" &&
                message.toolCallId === "child-mutation" &&
                message.isError &&
                JSON.stringify(message.content).includes(
                  "Return the required investigation to the parent.",
                ),
            ),
          });
          const content: AssistantMessage["content"] =
            calls++ === 0 && mode === "codemode"
              ? [
                  {
                    type: "toolCall",
                    id: "native-fixture",
                    name: "codemode",
                    arguments: {
                      code: `const plan = await tools.enter_plan_mode({}); try { await tools.write({path:'project.ts',content:'changed'}); } catch(error) { text(String(error)); } text(await tools.write({path:plan.path,content:'# Native plan\\n'}));`,
                    },
                  },
                ]
              : mode !== "codemode" && calls === 1
                ? [
                    {
                      type: "toolCall",
                      id: "enter-fixture",
                      name: "enter_plan_mode",
                      arguments: {},
                    },
                  ]
                : mode !== "codemode" && calls === 2
                  ? [
                      {
                        type: "toolCall",
                        id: "research-fixture",
                        name: "planning_research",
                        arguments: {
                          role: "explore",
                          brief: "Return the offline fixture report.",
                        },
                      },
                    ]
                  : mode === "research" && calls === 3
                    ? [
                        {
                          type: "toolCall",
                          id: "child-mutation",
                          name: "bash",
                          arguments: { command: "printf changed > project.ts" },
                        },
                      ]
                    : [{ type: "text", text: "Offline fixture report" }];
          const waitForCancel = mode === "research-cancel" && calls === 3;
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
            if (waitForCancel) {
              const abort = () => {
                childCancelled = true;
                stream.push({
                  type: "error",
                  reason: "aborted",
                  error: {
                    ...message,
                    stopReason: "aborted",
                    errorMessage: "Fixture child cancelled",
                  },
                });
                stream.end();
              };
              if (options?.signal?.aborted === true) {
                abort();
              } else {
                options?.signal?.addEventListener("abort", abort, {
                  once: true,
                });
              }
              childStarted.resolve();
              return;
            }
            stream.push({ type: "done", reason, message });
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
      await writeFile(join(cwd, "project.ts"), "original");
      const settings = SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
        defaultTools: ["+codemode"],
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
        extensionFactories: [
          provider,
          createCodemodeExtension({ mode: "on" }),
          subagents,
          planning,
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
        agentDir: join(cwd, "agent"),
        resourceLoader: loader,
        modelRuntime: runtime,
        model,
        thinkingLevel: "off",
        sessionManager: manager,
        settingsManager: settings,
        tools: [
          "read",
          "write",
          "edit",
          "bash",
          "codemode",
          "enter_plan_mode",
          "planning_research",
          "submit_plan",
        ],
      }));
      await session.bindExtensions({});
      const running = session.prompt("Exercise the fixed planning fixture.");
      if (mode === "research-cancel") {
        await childStarted.promise;
        await session.abort();
      }
      await running;
      const parentId = manager.getSessionId();
      const childRequests = requests.filter(
        (request) => request.sessionId !== parentId,
      );
      expect({
        project: await readFile(join(cwd, "project.ts"), "utf8"),
        streaming: session.isStreaming,
        childCancelled,
        sessions: requests.map((request) =>
          request.sessionId === parentId
            ? "parent"
            : typeof request.sessionId === "string"
              ? "child"
              : "missing",
        ),
        childSessionCount: new Set(
          childRequests.map((request) => request.sessionId),
        ).size,
        childTools: childRequests.map((request) => request.tools),
        blocked: childRequests.map((request) => request.guardBlocked),
      }).toStrictEqual({ project: "original", streaming: false, ...expected });
      if (mode === "research-cancel") {
        return;
      }
      const parent = session.messages.find(
        (message) =>
          message.role === "toolResult" &&
          message.toolCallId ===
            (mode === "codemode" ? "native-fixture" : "research-fixture"),
      );
      expect(parent).toMatchObject({ isError: false });
      if (parent?.role !== "toolResult") {
        throw new Error("Native codemode did not return a result");
      }
      expect(JSON.stringify(parent.content)).toContain(
        mode === "codemode"
          ? "Only the active plan may be edited"
          : "Offline fixture report",
      );
      const ceiling = resolveCurrentSubagentCapabilityCeiling(
        manager.getSessionId(),
      );
      expect(ceiling).toMatchObject({
        denyExtensions: false,
        allowedAgents: ["planning-explore", "planning-plan"],
      });
      const guard = fileURLToPath(new URL("../child.ts", import.meta.url));
      const launch = resolvePiLaunchToolPlan({
        agentName: "planning-explore",
        cwd,
        tools: ["read", "write", "bash", "ask_user", "subagent"],
        extensions: [guard],
        requiredExtensions: [
          { id: "planning-policy", path: guard, requireForAllRunners: true },
        ],
        capabilityCeiling: ceiling,
      });
      expect({
        tools: launch.effectiveToolAllowlist,
        required: launch.requiredExtensions.map(({ id }) => id),
      }).toStrictEqual({
        tools: ["read", "bash"],
        required: ["planning-policy"],
      });
    } finally {
      await session?.abort();
      session?.dispose();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
