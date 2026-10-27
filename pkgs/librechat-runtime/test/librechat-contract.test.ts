import { createRequire } from "node:module";
import { expect, it } from "vitest";
import { z } from "zod";
import { configuredPersonalAgents } from "../src/bootstrap.ts";
import { configureProviders, type ProviderOptions } from "../src/config.ts";

type NativeFunction = (...args: unknown[]) => unknown;

const callable = z.custom<NativeFunction>(
  (value) => typeof value === "function",
);
const models = {
  anthropic: "claude-model",
  openai: "gpt-model",
  openrouter: "router-model",
  ollama: "qwen3:4b",
};

const root = process.env.LIBRECHAT_TEST_ROOT;

if (root === undefined) {
  throw new Error(
    "Run tests in nix develop .#librechat-runtime to provide the pinned LibreChat package",
  );
}

process.env.LOG_TO_FILE = "false";

const require = createRequire(`${root}/package.json`);
const api = z
  .object({ createLoadConfigModels: callable, validateAgentModel: callable })
  .parse(require("@librechat/api"));
const dataProvider = z
  .object({ configSchema: z.object({ parse: callable }) })
  .parse(require("librechat-data-provider"));

it.each([
  { settings: {}, mode: "eager" },
  { settings: { authorizationMode: "eager" }, mode: "eager" },
  { settings: { authorizationMode: "nonblocking" }, mode: "nonblocking" },
])("preserves the MCP authorization mode $mode", ({ settings, mode }) => {
  const parsed: unknown = dataProvider.configSchema.parse({
    version: "1.3.18",
    mcpSettings: settings,
  });
  const result = z
    .object({ mcpSettings: z.object({ authorizationMode: z.string() }) })
    .parse(parsed);

  expect(result).toStrictEqual({ mcpSettings: { authorizationMode: mode } });
});

it("rejects an unsupported MCP authorization mode", () => {
  expect(() =>
    dataProvider.configSchema.parse({
      version: "1.3.18",
      mcpSettings: { authorizationMode: "sometimes" },
    }),
  ).toThrow(/authorizationMode/u);
});

it.each([
  { settings: {}, timeout: 3_000 },
  { settings: { initializationTimeoutMs: 500 }, timeout: 500 },
  { settings: { initializationTimeoutMs: 60_000 }, timeout: 60_000 },
])(
  "preserves the MCP initialization timeout $timeout",
  ({ settings, timeout }) => {
    const parsed: unknown = dataProvider.configSchema.parse({
      version: "1.3.18",
      mcpSettings: settings,
    });
    const result = z
      .object({
        mcpSettings: z.object({ initializationTimeoutMs: z.number() }),
      })
      .parse(parsed);

    expect(result).toStrictEqual({
      mcpSettings: { initializationTimeoutMs: timeout },
    });
  },
);

it.each([0, 60_001])("rejects the MCP initialization timeout %s", (timeout) => {
  expect(() =>
    dataProvider.configSchema.parse({
      version: "1.3.18",
      mcpSettings: { initializationTimeoutMs: timeout },
    }),
  ).toThrow(/initializationTimeoutMs/u);
});

it.each<{ options: ProviderOptions; catalog: string; model: string }>([
  {
    options: { ollamaUrl: "http://127.0.0.1:11434" },
    catalog: "ollama",
    model: models.ollama,
  },
  {
    options: { openrouterKeyFile: "/fixture/key" },
    catalog: "OpenRouter",
    model: models.openrouter,
  },
])(
  "generates agents accepted by LibreChat's $catalog model catalogue",
  async ({ options, catalog, model }) => {
    const providers = await configureProviders(
      options,
      async () => "fixture-key",
    );
    for (const endpoint of providers.endpoints.custom) {
      endpoint.models = { fetch: false, default: [model] };
    }

    const config = { endpoints: providers.endpoints };
    const loadModels = callable.parse(
      api.createLoadConfigModels({
        getAppConfig: async () => config,
        getUserKeyValues: async () => null,
      }),
    );
    const catalogs: unknown = await Promise.resolve(loadModels({ config }));
    const validations = await Promise.all(
      configuredPersonalAgents(options, models).map(async (agent) => ({
        provider: agent.provider,
        model: agent.model,
        result: await Promise.resolve(
          api.validateAgentModel({
            req: {},
            res: {},
            agent,
            modelsConfig: catalogs,
            logViolation: async () => {},
          }),
        ),
      })),
    );

    expect({ catalogs, validations }).toStrictEqual({
      catalogs: { [catalog]: [model] },
      validations: [{ provider: catalog, model, result: { isValid: true } }],
    });
  },
);
