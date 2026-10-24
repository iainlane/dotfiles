import {
  createAssistantMessageEventStream,
  type AssistantMessage,
} from "@earendil-works/pi-ai/compat";
import { runtimeFixture } from "./runtime.ts";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
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
  await vi.importActual("../.fixtures/rpiv-btw/btw.ts");
}, 30_000);

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
    const stream = vi.fn<ExtensionContext["modelRegistry"]["streamSimple"]>();
    for (const reply of replies) {
      stream.mockImplementationOnce(() => {
        const output = createAssistantMessageEventStream();
        output.end(reply);
        return output;
      });
    }
    const { context: ctx } = await runtimeFixture();
    ctx.cwd = "/fixture";
    ctx.model = {
      provider: "openai",
      id: "fixture",
      api: "openai-completions",
      name: "fixture",
      baseUrl: "http://127.0.0.1:1",
      contextWindow: 200000,
      maxTokens: 4096,
      reasoning: false,
      input: ["text"],
      cost: usage.cost,
    };
    vi.spyOn(ctx.sessionManager, "getSessionFile").mockReturnValue(
      `/fixture/${outcome}.jsonl`,
    );
    vi.spyOn(ctx.sessionManager, "getSessionId").mockReturnValue(outcome);
    vi.spyOn(ctx.modelRegistry, "getApiKeyAndHeaders").mockResolvedValue({
      ok: true,
    });
    vi.spyOn(ctx.modelRegistry, "streamSimple").mockImplementation(stream);
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
      }>("../.fixtures/rpiv-btw/btw.ts");
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
    const record = vi.fn<(response: unknown) => void>();
    const controller = new AbortController();
    const result = await executeBtw("Question", ctx, controller, record);
    expect({
      kind: result.kind,
      records: record.mock.calls.map(([value]) => value),
    }).toStrictEqual({
      kind: outcome === "aborted" ? "aborted" : "success",
      records: replies,
    });
    expect(stream.mock.calls.map((call) => call[2])).toStrictEqual(
      replies.map(() => ({ signal: controller.signal })),
    );
  },
);
