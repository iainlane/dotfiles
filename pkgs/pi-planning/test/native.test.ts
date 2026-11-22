import { existsSync, writeFileSync } from "node:fs";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Message,
  type Model,
} from "@earendil-works/pi-ai/compat";
import {
  createAgentSession,
  createCodemodeExtension,
  createMcpExtension,
  createToolSearchExtension,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import subagents from "pi-subagents";
import { fauxAssistantMessage, getCurrentTools } from "@earendil-works/pi-ai";
import { resolveCurrentSubagentCapabilityCeiling } from "pi-subagents/capability-ceiling";
import { resolvePiLaunchToolPlan } from "pi-subagents/child-tool-plan";
import { expect, it, vi } from "vitest";
import { Check } from "typebox/value";
import planning from "#planning/extension.ts";
import {
  enterPlanDescription,
  planDisplayType,
  planningPrompt,
} from "#planning/prompt.ts";
import { PlanStore } from "#planning/store.ts";
import { nodeFiles } from "#planning/node-files.ts";
import researchFixture from "./fixtures/research.ts";
import nativePermissionsFixture from "./fixtures/permissions.ts";
import {
  lastToolResult,
  toolCallReply,
  transcriptProvider,
  userText,
} from "./fixtures/faux.ts";

const nativeResearchTools = [
  "bash",
  "bg_wait",
  "codemode",
  "contact_supervisor",
  "find",
  "grep",
  "ls",
  "read",
  "subagent",
];
const mcpResearchTools = [...nativeResearchTools, "tool_search"].toSorted();
const mcpScript = `text('MCP_RESULT=' + JSON.stringify({resources:await tools.list_mcp_resources({server:'fixture'}),templates:await tools.list_mcp_resource_templates({server:'fixture'}),document:await tools.read_mcp_resource({server:'fixture',uri:'fixture://document'})}));`;
const fixtureTools = [
  "ast_grep_replace",
  "project_report",
  "lsp_navigation",
  "pi_lens_activate_tools",
  "web_enable",
  "web_search",
];
const extendedResearchTools = [
  ...nativeResearchTools,
  ...fixtureTools,
].toSorted();
const initialResearchTools = extendedResearchTools.filter(
  (name) =>
    !["web_search", "lsp_navigation", "ast_grep_replace"].includes(name),
);
const researchScript = `text(await tools.web_enable({})); text(await tools.pi_lens_activate_tools({tools:['lsp_navigation']})); text(await tools.web_search({})); text(await tools.project_report({})); text(await tools.mcp__fixture__inspect_tool({})); try { await tools.mcp__fixture__mutate_tool({}); throw new Error('Expected native permission refusal'); } catch(error) { if (!String(error).includes('Native permission fixture refused')) throw error; text(String(error)); } text(await tools.lsp_navigation({operation:'definition'})); text(await tools.ast_grep_replace({apply:false})); try { await tools.lsp_navigation({operation:'rename',apply:true}); } catch(error) { text(String(error)); }`;

it("declares strict empty model-only planning inputs and structured outputs in the native registry", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-planning-contracts-"));
  vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
  let session:
    | Awaited<ReturnType<typeof createAgentSession>>["session"]
    | undefined;
  try {
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false },
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
      extensionFactories: [planning],
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
      sessionManager: SessionManager.create(cwd, join(cwd, "sessions")),
      settingsManager: settings,
    }));
    const active = session;
    expect(
      ["enter_plan_mode", "submit_plan"].map((name) => {
        const tool = active.getToolDefinition(name);
        if (!tool) {
          throw new Error(`Missing native planning tool ${name}`);
        }
        return {
          name,
          exposure: tool.exposure,
          executionMode: tool.executionMode,
          validEmpty: Check(tool.parameters, {}),
          acceptsExtra: Check(tool.parameters, { compatibility: true }),
          output: tool.outputSchema !== undefined,
          active: active.getActiveToolNames().includes(name),
        };
      }),
    ).toStrictEqual(
      ["enter_plan_mode", "submit_plan"].map((name) => ({
        name,
        exposure: "model-only",
        executionMode: "sequential",
        validEmpty: true,
        acceptsExtra: false,
        output: true,
        active: name === "enter_plan_mode",
      })),
    );
  } finally {
    session?.dispose();
    vi.unstubAllEnvs();
    await rm(cwd, { recursive: true, force: true });
  }
});

it("shows plan review only in active planning across reload, resume and tree navigation", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "pi-planning-tool-visibility-"));
  const agentDir = join(cwd, "agent");
  vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
  let session:
    | Awaited<ReturnType<typeof createAgentSession>>["session"]
    | undefined;
  try {
    const settings = SettingsManager.inMemory({
      compaction: { enabled: false },
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
      extensionFactories: [subagents, planning],
    });
    const runtime = await ModelRuntime.create({
      authPath: join(cwd, "auth.json"),
      modelsPath: join(cwd, "models.json"),
    });
    const open = async (manager: SessionManager) => {
      await loader.reload();
      const created = await createAgentSession({
        cwd,
        agentDir,
        resourceLoader: loader,
        modelRuntime: runtime,
        sessionManager: manager,
        settingsManager: settings,
      });
      session = created.session;
      await session.bindExtensions({ mode: "rpc" });
      return session;
    };
    const manager = SessionManager.create(cwd, join(cwd, "sessions"));
    manager.appendMessage({
      role: "user",
      content: "Inspect the tool visibility fixture.",
      timestamp: 1,
    });
    const active = await open(manager);
    active.setActiveToolsByName(["enter_plan_mode", "read", "grep"]);
    const snapshots: { phase: string; tools: string[] }[] = [];
    const capture = (phase: string) => {
      if (!session) {
        throw new Error("The visibility fixture session is unavailable.");
      }
      snapshots.push({
        phase,
        tools: session
          .getActiveToolNames()
          .filter((name) => ["enter_plan_mode", "submit_plan"].includes(name))
          .toSorted(),
      });
    };
    capture("ordinary");
    await active.prompt("/plan");
    capture("entry");
    const otherToolsAfterEntry = active
      .getActiveToolNames()
      .filter((name) => !["enter_plan_mode", "submit_plan"].includes(name))
      .toSorted();
    await active.reload();
    capture("reload");
    const file = manager.getSessionFile();
    if (file === undefined) {
      throw new Error("The visibility fixture must persist its session.");
    }
    await active.extensionRunner.emit({
      type: "session_shutdown",
      reason: "quit",
    });
    active.dispose();
    const resumed = await open(SessionManager.open(file));
    capture("resume");
    await resumed.prompt("/plan exit");
    capture("exit");
    const inactiveEntry = resumed.sessionManager.getLeafId();
    await resumed.prompt("/plan");
    capture("reentry");
    const activeEntry = resumed.sessionManager.getLeafId();
    if (inactiveEntry === null || activeEntry === null) {
      throw new Error("Expected persisted planning state entries.");
    }
    await resumed.navigateTree(inactiveEntry, { summarize: false });
    capture("inactive branch");
    await resumed.navigateTree(activeEntry, { summarize: false });
    capture("active branch");
    await resumed.prompt("/plan exit");
    capture("exit after tree");
    await resumed.reload();
    capture("inactive reload");
    await resumed.extensionRunner.emit({
      type: "session_shutdown",
      reason: "quit",
    });
    resumed.dispose();
    await open(SessionManager.open(file));
    capture("inactive resume");

    const ordinary = ["enter_plan_mode"];
    const planningTools = [...ordinary, "submit_plan"];
    expect({ otherToolsAfterEntry, snapshots }).toStrictEqual({
      otherToolsAfterEntry: ["grep", "read"],
      snapshots: [
        { phase: "ordinary", tools: ordinary },
        { phase: "entry", tools: planningTools },
        { phase: "reload", tools: planningTools },
        { phase: "resume", tools: planningTools },
        { phase: "exit", tools: ordinary },
        { phase: "reentry", tools: planningTools },
        { phase: "inactive branch", tools: ordinary },
        { phase: "active branch", tools: planningTools },
        { phase: "exit after tree", tools: ordinary },
        { phase: "inactive reload", tools: ordinary },
        { phase: "inactive resume", tools: ordinary },
      ],
    });
  } finally {
    await session?.extensionRunner.emit({
      type: "session_shutdown",
      reason: "quit",
    });
    session?.dispose();
    vi.unstubAllEnvs();
    await rm(cwd, { recursive: true, force: true });
  }
});

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
    const provider: ExtensionFactory = (pi) => {
      pi.registerProvider(model.provider, {
        apiKey: "fixture",
        api: model.api,
        baseUrl: model.baseUrl,
        models: [model],
        streamSimple: (_model, context) => {
          const slow = JSON.stringify(
            context.messages.findLast((entry) => entry.role === "user")
              ?.content,
          ).includes("Investigate slowly");
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
          const finishAfterRelease = async () => {
            try {
              await release.promise;
              finish();
            } catch (error) {
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
            }
          };
          queueMicrotask(() => {
            stream.push({ type: "start", partial: assistant });
            if (!slow) {
              finish();
              return;
            }
            ready.resolve();
            void finishAfterRelease();
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
      const queued = new Promise<void>((resolve) => {
        const unsubscribe = activeSession.subscribe((event) => {
          if (event.type === "queue_update" && event.steering.length > 0) {
            unsubscribe();
            resolve();
          }
        });
      });
      await session.prompt(`/plan ${command}`);
      await queued;
      expect(activeSession.getSteeringMessages()).toStrictEqual([message]);
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
      const plan = new PlanStore(
        join(cwd, "agent", "plans"),
        session.sessionManager.getSessionId(),
        nodeFiles,
      ).write("# Displayed plan\n");
      const messagesBefore = [...session.messages];
      await session.prompt("/plan");
      await session.prompt("/plan");
      expect({
        messages: session.messages,
        displays: session.sessionManager
          .getBranch()
          .flatMap((entry) =>
            entry.type === "custom" && entry.customType === planDisplayType
              ? [entry.data]
              : [],
          ),
      }).toStrictEqual({
        messages: messagesBefore,
        displays: [plan, plan],
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

type TranscriptStep =
  | { user: string[] }
  | {
      tools: string[];
      reply: string[];
      stopReason: AssistantMessage["stopReason"];
    }
  | { result: string; isError: boolean; text: unknown[] };

function textBlocks(content: Message["content"]): string[] {
  return typeof content === "string"
    ? [content]
    : content.flatMap((block) => (block.type === "text" ? [block.text] : []));
}

/**
 * Summarises a session's messages. Each reply lists the tools that `shown`
 * accepts from those available when the model produced it.
 */
function transcript(
  messages: Message[],
  shown: (tool: string) => boolean,
): TranscriptStep[] {
  return messages.flatMap((message, index): TranscriptStep[] => {
    if (message.role === "user") {
      return [{ user: textBlocks(message.content) }];
    }

    if (message.role === "assistant") {
      return [
        {
          tools: getCurrentTools(messages.slice(0, index))
            .map((tool) => tool.name)
            .filter((tool) => shown(tool))
            .toSorted(),
          reply: message.content.flatMap((block) =>
            block.type === "toolCall"
              ? [block.id]
              : block.type === "text"
                ? [block.text]
                : [],
          ),
          stopReason: message.stopReason,
        },
      ];
    }

    if (message.role === "toolResult") {
      return [
        {
          result: message.toolCallId,
          isError: message.isError,
          text: textBlocks(message.content),
        },
      ];
    }

    return [];
  });
}

/**
 * Reads the messages of the session in `file` and of every child session that
 * pi-subagents stored beside it, ordered by nesting depth.
 */
async function sessionMessages(file: string): Promise<Message[][]> {
  const children = file.slice(0, -".jsonl".length);
  const files = existsSync(children)
    ? (await readdir(children, { recursive: true }))
        .filter((path) => path.endsWith("session.jsonl"))
        .toSorted((a, b) => a.split("/").length - b.split("/").length)
        .map((path) => join(children, path))
    : [];
  return [file, ...files].map((path) =>
    SessionManager.open(path)
      .getBranch()
      .flatMap((entry): Message[] => {
        if (entry.type !== "message") {
          return [];
        }
        const { message } = entry;
        return message.role === "system" ||
          message.role === "user" ||
          message.role === "assistant" ||
          message.role === "toolResult"
          ? [message]
          : [];
      }),
  );
}

const planningTools = ["enter_plan_mode", "submit_plan"];
const fixturePrompt = { user: ["Exercise the fixed planning fixture."] };
const childPrompt = { user: ["Task: Return the offline fixture report."] };
const call = (tools: string[], id: string): TranscriptStep => ({
  tools,
  reply: [id],
  stopReason: "toolUse",
});
const report = (tools: string[]): TranscriptStep => ({
  tools,
  reply: ["Offline fixture report"],
  stopReason: "stop",
});
const aborted = (tools: string[]): TranscriptStep => ({
  tools,
  reply: [],
  stopReason: "aborted",
});
const result = (
  id: string,
  text: unknown[],
  isError = false,
): TranscriptStep => ({ result: id, isError, text });
const entered = (plan: string): TranscriptStep[] => [
  fixturePrompt,
  call(["enter_plan_mode"], "enter-fixture"),
  result("enter-fixture", [planningPrompt(plan)]),
];
function literal(text: string): string {
  return text.replaceAll(/[\\^$.*+?()[\]{}|/]/gu, "\\$&");
}

/**
 * Matches text that contains each of `texts` in order. Codemode and
 * pi-subagents decide how they frame the output of the tools and children
 * that planning allows, so only that output is compared.
 */
function inOrder(...texts: string[]): unknown {
  return expect.stringMatching(
    new RegExp(texts.map((text) => literal(text)).join("[\\s\\S]*"), "u"),
  );
}
const anyText: unknown = expect.any(String);
const scriptOutput = (...texts: string[]) => [anyText, inOrder(...texts)];
const researchOutput = scriptOutput(
  "fixture:web_enable",
  "fixture:pi_lens_activate_tools",
  "fixture:web_search",
  "fixture:project_report",
  JSON.stringify({ content: [{ type: "text", text: "fixture:mcp" }] }),
  "Error: Native permission fixture refused {}",
  "fixture:lsp_navigation",
  "fixture:ast_grep_replace",
  "Error: Only previews are available before plan approval.",
);
const delegated = (plan: string): TranscriptStep[] => [
  ...entered(plan),
  call(planningTools, "research-fixture"),
  result("research-fixture", [inOrder("Offline fixture report")]),
  report(planningTools),
];
const refusedMutation: TranscriptStep[] = [
  childPrompt,
  call(nativeResearchTools, "child-mutation"),
  result(
    "child-mutation",
    [
      `Native permission fixture refused ${JSON.stringify({ command: "printf changed > project.ts" })}`,
    ],
    true,
  ),
  report(nativeResearchTools),
];
const mcpTools = [...mcpResearchTools, "mcp__fixture__inspect_tool"].toSorted();
const mcpDocument = {
  resources: {
    server: "fixture",
    resources: [
      { server: "fixture", uri: "fixture://document", name: "document" },
    ],
  },
  templates: {
    server: "fixture",
    resourceTemplates: [
      { server: "fixture", uriTemplate: "fixture://{name}", name: "document" },
    ],
  },
  document: {
    server: "fixture",
    uri: "fixture://document",
    contents: [
      { uri: "fixture://document", text: "Offline resource contents." },
    ],
  },
};
const nestedResearch = (task: string, delegation: TranscriptStep[]) => [
  { user: [`Task: ${task}`] },
  call(initialResearchTools, "research-script"),
  result("research-script", researchOutput),
  ...delegation,
  report(extendedResearchTools),
];

const registerResearchToolsAfterPlanningStarts: ExtensionFactory = (pi) => {
  pi.on("session_start", () => researchFixture(pi));
};

it.each<{ mode: string; sessions: (plan: string) => TranscriptStep[][] }>([
  {
    mode: "codemode",
    sessions: (plan) => [
      [
        ...entered(plan),
        call(planningTools, "native-fixture"),
        result(
          "native-fixture",
          scriptOutput(
            `Error: Only the active plan may be edited: ${plan}`,
            `Successfully wrote to ${plan}`,
          ),
        ),
        report(planningTools),
      ],
    ],
  },
  {
    mode: "research",
    sessions: (plan) => [delegated(plan), refusedMutation],
  },
  {
    mode: "settings-error",
    sessions: (plan) => [delegated(plan), refusedMutation],
  },
  {
    mode: "research-cancel",
    sessions: (plan) => [
      [
        ...entered(plan),
        call(planningTools, "research-fixture"),
        result("research-fixture", [inOrder("Request was aborted")], true),
        aborted(planningTools),
      ],
      [childPrompt, aborted(nativeResearchTools)],
    ],
  },
  {
    mode: "mcp",
    sessions: (plan) => [
      delegated(plan),
      [
        childPrompt,
        call(mcpResearchTools, "mcp-search"),
        result("mcp-search", [anyText]),
        call(mcpTools, "mcp-script"),
        result("mcp-script", [
          anyText,
          inOrder(`MCP_RESULT=${JSON.stringify(mcpDocument)}`),
        ]),
        report(mcpTools),
      ],
    ],
  },
  {
    mode: "nested",
    sessions: (plan) => [
      delegated(plan),
      nestedResearch("Return the offline fixture report.", [
        call(extendedResearchTools, "nested-research"),
        result("nested-research", [inOrder("Offline fixture report")]),
      ]),
      nestedResearch("Inspect the nested research fixture.", [
        call(extendedResearchTools, "depth-limit"),
        result("depth-limit", [anyText], true),
      ]),
    ],
  },
])(
  "runs $mode through native planning and resolves a guarded child launch",
  async ({ mode, sessions }) => {
    const cwd = await realpath(
      await mkdtemp(join(tmpdir(), "pi-planning-native-")),
    );
    vi.stubEnv("PI_CODING_AGENT_DIR", join(cwd, "agent"));
    const fixtureModel: Model<"planning-fixture"> = {
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
    let planPath = "";
    const hasMcp = mode === "nested" || mode === "mcp";
    const gate = join(cwd, "mcp-ready");
    const mcpConfig = (gated: boolean) =>
      JSON.stringify({
        mcpServers: {
          fixture: {
            command: process.execPath,
            args: [
              fileURLToPath(new URL("./fixtures/mcp.ts", import.meta.url)),
              ...(gated ? [gate] : []),
            ],
          },
        },
      });
    const childStarted = Promise.withResolvers<void>();
    const faux = transcriptProvider(fixtureModel, async (context, options) => {
      const task = userText(context.messages);
      const last = lastToolResult(context.messages);
      if (task.includes("Exercise the fixed planning fixture.")) {
        if (last === undefined) {
          return toolCallReply("enter-fixture", "enter_plan_mode", {});
        }
        if (last === "enter-fixture" && mode === "codemode") {
          return toolCallReply("native-fixture", "codemode", {
            code: `try { await tools.write({path:'project.ts',content:'changed'}); } catch(error) { text(String(error)); } text(await tools.write({path:${JSON.stringify(planPath)},content:'# Native plan\\n'}));`,
          });
        }
        if (last === "enter-fixture") {
          if (mode === "mcp") {
            writeFileSync(join(cwd, "agent", "mcp.json"), mcpConfig(true));
          }
          return toolCallReply("research-fixture", "subagent", {
            agent: "planning-explore",
            task: "Return the offline fixture report.",
            async: false,
          });
        }
        return fauxAssistantMessage("Offline fixture report");
      }
      if (mode === "research-cancel") {
        const signal = options?.signal;
        childStarted.resolve();
        if (signal !== undefined && !signal.aborted) {
          await new Promise((resolve) => {
            signal.addEventListener("abort", resolve, { once: true });
          });
        }
        return fauxAssistantMessage([], {
          stopReason: "aborted",
          errorMessage: "Fixture child cancelled",
        });
      }
      if (last === undefined && mode === "mcp") {
        writeFileSync(gate, "");
        return toolCallReply("mcp-search", "tool_search", {
          query: "mcp__fixture__inspect_tool",
          limit: 1,
        });
      }
      if (last === undefined && mode === "nested") {
        return toolCallReply("research-script", "codemode", {
          code: researchScript,
        });
      }
      if (last === undefined) {
        if (mode === "settings-error") {
          writeFileSync(join(cwd, "agent", "planning.json"), "{invalid");
        }
        return toolCallReply("child-mutation", "bash", {
          command: "printf changed > project.ts",
        });
      }
      if (last === "mcp-search") {
        return toolCallReply("mcp-script", "codemode", { code: mcpScript });
      }
      if (last === "research-script") {
        return task.includes("Inspect the nested research fixture.")
          ? toolCallReply("depth-limit", "subagent", {
              agent: "planning-explore",
              task: "This exceeds the configured depth.",
              async: false,
            })
          : toolCallReply("nested-research", "subagent", {
              agent: "planning-plan",
              task: "Inspect the nested research fixture.",
              async: false,
            });
      }
      return fauxAssistantMessage("Offline fixture report");
    });
    const provider: ExtensionFactory = (pi) => {
      pi.registerProvider(faux.provider);
    };
    let session:
      | Awaited<ReturnType<typeof createAgentSession>>["session"]
      | undefined;
    try {
      await writeFile(join(cwd, "project.ts"), "original");
      await mkdir(join(cwd, "agent"), { recursive: true });
      await writeFile(
        join(cwd, "agent", "planning.json"),
        JSON.stringify({
          researchExtensions: [
            fileURLToPath(
              new URL("./fixtures/permissions.ts", import.meta.url),
            ),
            ...(mode === "nested"
              ? [
                  fileURLToPath(
                    new URL("./fixtures/research.ts", import.meta.url),
                  ),
                ]
              : []),
          ],
        }),
      );
      if (mode === "nested") {
        await writeFile(
          join(cwd, "agent", "settings.json"),
          JSON.stringify({ subagents: { maxSubagentDepth: 2 } }),
        );
      }
      if (hasMcp) {
        await writeFile(join(cwd, "agent", "mcp.json"), mcpConfig(false));
      }
      const settings = SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
        defaultTools: [
          "read",
          "write",
          "edit",
          "bash",
          "grep",
          "find",
          "ls",
          "codemode",
          ...(mode === "mcp" ? ["tool_search"] : []),
        ],
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
        additionalExtensionPaths: hasMcp ? ["builtin:mcp"] : [],
        extensionFactories: [
          provider,
          nativePermissionsFixture,
          ...(mode === "mcp" ? [createToolSearchExtension()] : []),
          ...(hasMcp
            ? [
                {
                  name: "mcp",
                  builtin: true as const,
                  replaceable: true as const,
                  // Node fires a timer with a longer delay, Infinity included, after 1 ms.
                  factory: createMcpExtension({ startupWaitMs: 2 ** 31 - 1 }),
                },
              ]
            : []),
          createCodemodeExtension({ mode: "on" }),
          subagents,
          planning,
          ...(mode === "nested"
            ? [registerResearchToolsAfterPlanningStarts]
            : []),
        ],
      });
      await loader.reload();
      const runtime = await ModelRuntime.create({
        authPath: join(cwd, "auth.json"),
        modelsPath: join(cwd, "models.json"),
      });
      const manager = SessionManager.create(cwd, join(cwd, "sessions"));
      planPath = new PlanStore(
        join(cwd, "agent", "plans"),
        manager.getSessionId(),
        nodeFiles,
      ).path;
      ({ session } = await createAgentSession({
        cwd,
        agentDir: join(cwd, "agent"),
        resourceLoader: loader,
        modelRuntime: runtime,
        model: faux.getModel(),
        thinkingLevel: "off",
        sessionManager: manager,
        settingsManager: settings,
      }));
      await session.bindExtensions({
        mode: "rpc",
        uiContext: {
          ...session.extensionRunner.getUIContext(),
          confirm: async (title) => title === "Enter Plan mode?",
        },
      });
      const running = session.prompt("Exercise the fixed planning fixture.");
      if (mode === "research-cancel") {
        await childStarted.promise;
        await session.abort();
      }
      await running;
      const file = manager.getSessionFile();
      if (file === undefined) {
        throw new Error("The native fixture must persist its session.");
      }
      const [parent = [], ...children] = await sessionMessages(file);
      const ceiling = resolveCurrentSubagentCapabilityCeiling(
        manager.getSessionId(),
      );
      expect({
        project: await readFile(join(cwd, "project.ts"), "utf8"),
        streaming: session.isStreaming,
        entryDescription: getCurrentTools(parent).find(
          (tool) => tool.name === "enter_plan_mode",
        )?.description,
        sessions: [
          transcript(parent, (tool) => planningTools.includes(tool)),
          ...children.map((messages) => transcript(messages, () => true)),
        ],
        ceiling,
      }).toStrictEqual({
        project: "original",
        streaming: false,
        entryDescription: enterPlanDescription,
        sessions: sessions(planPath),
        ceiling: {
          version: 1,
          sources: ["planning"],
          denyExtensions: false,
          allowedAgents: ["planning-explore", "planning-plan"],
        },
      });
      if (mode === "research-cancel") {
        return;
      }
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
        tools: ["read", "write", "bash", "ask_user", "subagent"],
        required: ["planning-policy"],
      });
    } finally {
      writeFileSync(gate, "");
      await session?.abort();
      session?.dispose();
      vi.unstubAllEnvs();
      await rm(cwd, { recursive: true, force: true });
    }
  },
);
