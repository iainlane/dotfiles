import {
  createAssistantMessageEventStream,
  type AssistantMessage,
} from "@earendil-works/pi-ai/compat";
import { runtimeFixture } from "#test/support/runtime.ts";
import {
  ModelRegistry,
  ModelRuntime,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
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

it.each(["success", "overflow", "aborted"])(
  "uses public streaming and records every %s response",
  async (outcome) => {
    const replies: AssistantMessage[] =
      outcome === "overflow"
        ? [
            {
              ...response,
              stopReason: "error",
              errorMessage: "maximum context length exceeded",
            },
            response,
          ]
        : [
            {
              ...response,
              stopReason: outcome === "aborted" ? "aborted" : "stop",
            },
          ];
    const queued = [...replies];
    const requested = Promise.withResolvers<void>();
    const { context: ctx } = await runtimeFixture();

    if (configDirectory === undefined) {
      throw new Error("Expected the configuration directory");
    }

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
      streamSimple: (_model, _context, options) => {
        const output = createAssistantMessageEventStream();
        const reply = queued.shift();

        if (reply === undefined) {
          throw new Error("The fixture provider has no reply left");
        }

        requested.resolve();

        if (reply.stopReason !== "aborted") {
          output.end(reply);

          return output;
        }

        // The aborted reply is sent only when the request's signal aborts. A
        // request without a signal cannot be cancelled, so it completes with
        // the successful response.
        const signal = options?.signal;

        if (signal === undefined) {
          output.end(response);

          return output;
        }

        signal.addEventListener("abort", () => output.end(reply), {
          once: true,
        });

        return output;
      },
    });

    const model = ctx.modelRegistry.find("btw-fixture", "fixture");

    if (model === undefined) {
      throw new Error("Expected the registered fixture model");
    }

    ctx.cwd = "/fixture";
    ctx.model = model;

    const { executeBtw, buildBtwMessages, BTW_STATE_KEY } =
      await vi.importActual<{
        executeBtw: (
          question: string,
          ctx: ExtensionContext,
          controller: AbortController,
          record: (response: unknown) => void,
        ) => Promise<{ kind: string }>;
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

    const records: unknown[] = [];
    const controller = new AbortController();
    const execution = executeBtw("Question", ctx, controller, (value) => {
      records.push(value);
    });

    if (outcome === "aborted") {
      await Promise.race([requested.promise, execution]);
      controller.abort();
    }

    const result = await execution;

    expect({ kind: result.kind, records }).toStrictEqual({
      kind: outcome === "aborted" ? "aborted" : "success",
      records: replies,
    });
  },
);
