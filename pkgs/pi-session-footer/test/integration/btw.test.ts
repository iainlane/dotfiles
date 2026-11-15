import {
  createAssistantMessageEventStream,
  type AssistantMessage,
} from "@earendil-works/pi-ai/compat";
import { bindModel } from "#test/support/bound-runner.ts";
import { editorFixture } from "#test/support/editor.ts";
import { runtimeFixture } from "#test/support/runtime.ts";
import {
  ModelRegistry,
  ModelRuntime,
  SessionManager,
  type ExtensionAPI,
  type ExtensionContext,
  type ExtensionUIContext,
  type ProviderConfig,
} from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";
import { join } from "node:path";
import { setImmediate } from "node:timers/promises";
import { afterAll, beforeAll, expect, it, vi } from "vitest";

let configDirectory: string | undefined;

beforeAll(async () => {
  const fs = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const paths = await import("node:path");
  configDirectory = await fs.mkdtemp(paths.join(tmpdir(), "pi-btw-config-"));
  vi.stubEnv("XDG_CONFIG_HOME", configDirectory);
  await fs.mkdir(paths.join(configDirectory, "rpiv-btw"));
  await fs.writeFile(
    paths.join(configDirectory, "rpiv-btw/config.json"),
    JSON.stringify({ crossSessionHint: false }),
  );
  await vi.importActual("#fixtures/rpiv-btw/btw.ts");
});

afterAll(async () => {
  vi.unstubAllEnvs();
  const fs = await import("node:fs/promises");
  if (configDirectory !== undefined && configDirectory !== "") {
    await fs.rm(configDirectory, { recursive: true, force: true });
  }
});

const usage = {
  input: 100,
  output: 10,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 110,
  cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, total: 2 },
};
const response = {
  role: "assistant",
  api: "openai-completions",
  provider: "openai",
  model: "fixture",
  content: [{ type: "text", text: "Side answer" }],
  usage,
  stopReason: "stop",
  timestamp: 1,
} satisfies AssistantMessage;

const overflow = {
  ...response,
  content: [],
  usage: {
    ...usage,
    output: 0,
    totalTokens: 100,
    cost: { ...usage.cost, output: 0, total: 1 },
  },
  stopReason: "error",
  errorMessage: "maximum context length exceeded",
} satisfies AssistantMessage;

const aborted = {
  ...response,
  usage: {
    ...usage,
    output: 3,
    totalTokens: 103,
    cost: { ...usage.cost, output: 0.5, total: 1.5 },
  },
  stopReason: "aborted",
} satisfies AssistantMessage;

/**
 * Replies like a provider that accepts requests of up to `limit` characters of
 * messages and rejects larger ones as a context overflow. A provider that
 * `waits` sends its reply only when the request's signal aborts.
 */
function provider(limit: number, waits: boolean) {
  const requested = Promise.withResolvers<void>();
  const stream: ProviderConfig["streamSimple"] = (_model, context, options) => {
    const output = createAssistantMessageEventStream();

    requested.resolve();

    if (JSON.stringify(context.messages).length > limit) {
      output.end(overflow);

      return output;
    }

    const signal = options?.signal;

    if (!waits || signal === undefined) {
      output.end(response);

      return output;
    }

    signal.addEventListener("abort", () => output.end(aborted), {
      once: true,
    });

    return output;
  };

  return { requested: requested.promise, stream };
}

/** Shows custom components as Pi does and passes keys to the latest one. */
class OverlayHost {
  private component: Component | undefined;
  private readonly fixture = editorFixture();
  private readonly theme: ExtensionUIContext["theme"];

  constructor(theme: ExtensionUIContext["theme"]) {
    this.theme = theme;
  }

  readonly custom: ExtensionUIContext["custom"] = (factory) =>
    new Promise((resolve) => {
      void this.show(
        factory(this.fixture.tui, this.theme, this.fixture.keys, resolve),
      );
    });

  private async show(component: Component | Promise<Component>): Promise<void> {
    this.component = await component;
  }

  press(key: string): void {
    this.component?.handleInput?.(key);
  }
}

const generatedId: unknown = expect.any(String);
const generatedTimestamp: unknown = expect.any(String);
const uuid: unknown = expect.stringMatching(
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u,
);

/** The session entry for a usage record of `message`. */
function usageEntry(message: AssistantMessage) {
  return {
    type: "custom",
    customType: "rpiv-btw:usage:v1",
    data: {
      version: 1,
      id: uuid,
      source: "btw",
      provider: message.provider,
      model: message.model,
      usage: message.usage,
    },
    id: generatedId,
    parentId: generatedId,
    timestamp: generatedTimestamp,
  };
}

it.each([
  {
    outcome: "success",
    branch: "Earlier question",
    limit: Infinity,
    waits: false,
    recorded: [response],
  },
  {
    outcome: "overflow",
    branch: "x".repeat(600_000),
    limit: 450_000,
    waits: false,
    recorded: [overflow, response],
  },
  {
    outcome: "aborted",
    branch: "Earlier question",
    limit: Infinity,
    waits: true,
    recorded: [aborted],
  },
])(
  "appends a usage entry to the session for every $outcome response",
  async ({ branch, limit, waits, recorded }) => {
    const fixture = provider(limit, waits);
    const { api, context: ctx, runner } = await runtimeFixture();

    if (configDirectory === undefined) {
      throw new Error("Expected the configuration directory");
    }

    const session = SessionManager.inMemory("/fixture");

    session.appendMessage({ role: "user", content: branch, timestamp: 0 });
    const seeded = session.getEntries().length;
    ctx.sessionManager = session;
    ctx.modelRegistry = new ModelRegistry(
      await ModelRuntime.create({
        authPath: join(configDirectory, "auth.json"),
        modelsPath: null,
        refreshOnCreate: false,
      }),
    );
    ctx.modelRegistry.registerProvider("btw-fixture", {
      baseUrl: "http://127.0.0.1:1",
      apiKey: "fixture",
      api: "btw-fixture",
      models: [
        {
          id: "fixture",
          name: "fixture",
          reasoning: false,
          input: ["text"],
          cost: usage.cost,
          contextWindow: 200_000,
          maxTokens: 4096,
        },
      ],
      streamSimple: fixture.stream,
    });

    const model = ctx.modelRegistry.find("btw-fixture", "fixture");

    if (model === undefined) {
      throw new Error("Expected the registered fixture model");
    }

    ctx.cwd = "/fixture";
    ctx.model = model;

    const host = new OverlayHost(ctx.ui.theme);

    ctx.ui = { ...ctx.ui, custom: host.custom };
    bindModel(runner, () => model, session);

    const { registerBtwCommand, buildBtwMessages, BTW_STATE_KEY } =
      await vi.importActual<{
        registerBtwCommand: (api: ExtensionAPI) => void;
        buildBtwMessages: (
          ctx: ExtensionContext,
          message: { role: "user"; content: string; timestamp: number },
        ) => { systemPrompt: string };
        BTW_STATE_KEY: symbol;
      }>("#fixtures/rpiv-btw/btw.ts");
    Object.assign(globalThis, {
      [BTW_STATE_KEY]: {
        histories: new Map([
          [
            "unrelated",
            [
              {
                userMessage: {
                  role: "user",
                  content: "Private question from another project",
                  timestamp: 0,
                },
                assistantMessage: response,
              },
            ],
          ],
        ]),
        snapshots: new Map(),
      },
    });
    expect(
      buildBtwMessages(ctx, { role: "user", content: "Question", timestamp: 1 })
        .systemPrompt,
    ).not.toContain("Private question");

    registerBtwCommand(api);

    const command = runner.getCommand("btw");

    if (command === undefined) {
      throw new Error("Expected the /btw command");
    }

    const running = command.handler("Question", ctx);

    await fixture.requested;

    if (!waits) {
      await setImmediate();
    }

    host.press("\u001B");
    await running;

    expect(session.getEntries().slice(seeded)).toStrictEqual(
      recorded.map((message) => usageEntry(message)),
    );
  },
);
