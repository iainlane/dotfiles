import { createRequire } from "node:module";
import { afterEach, expect, it, vi } from "vitest";
import { z } from "zod";
import {
  configuredPersonalAgents,
  personalAgentData,
} from "../src/bootstrap.ts";
import {
  configureChatPrompts,
  configureProviders,
  type ProviderOptions,
} from "../src/config.ts";
import { CODE_ENVIRONMENT_ID } from "../src/identity.ts";

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
  .object({
    createLoadConfigModels: callable,
    validateAgentModel: callable,
    loadEphemeralAgent: callable,
    resolveAgentCodeExecution: callable,
    createChatPromptService: callable,
  })
  .parse(require("@librechat/api"));
const dataProvider = z
  .object({
    configSchema: z.object({ parse: callable }),
    replaceSpecialVars: callable,
  })
  .parse(require("librechat-data-provider"));

afterEach(() => {
  vi.unstubAllEnvs();
});

it("preserves the managed chat prompt and default in LibreChat configuration", () => {
  const prompts = configureChatPrompts("Ordinary chat instructions");
  const parsed: unknown = dataProvider.configSchema.parse({
    version: "1.3.18",
    prompts,
  });

  expect(z.object({ prompts: z.unknown() }).parse(parsed)).toStrictEqual({
    prompts,
  });
});

it("resolves built-in context from a configured default prompt", async () => {
  const prompt = "Model: {{current_model}}. Date: {{current_date}}.";
  const groupId = "123456789012345678901234";
  const service = z.object({ resolveInstructions: callable }).parse(
    api.createChatPromptService({
      ensureCatalog: async () => new Map([["general-assistant", groupId]]),
      canUsePrompts: async () => true,
      getEffectivePermissions: async () => 1,
      promptService: {
        getPromptGroup: async () => ({
          ok: true,
          value: { _id: groupId, source: "config", name: "General assistant" },
        }),
        resolvePrompt: async () => ({
          ok: true,
          value: { source: "config", groupId, type: "text", prompt },
        }),
      },
    }),
  );
  const instructions = z.string().parse(
    await service.resolveInstructions({
      user: { id: "fixture-user" },
      config: { prompts: configureChatPrompts(prompt) },
    }),
  );

  expect(
    dataProvider.replaceSpecialVars({
      text: instructions,
      model: "fixture-model",
      now: "2026-10-28T12:00:00Z",
      timezone: "UTC",
    }),
  ).toBe("Model: fixture-model. Date: 2026-10-28 (Wednesday).");
});

const codeRoute = z.object({
  statefulSessions: z.boolean(),
  statefulCodeEnvironment: z.string(),
  context: z.looseObject({
    baseUrl: z.string(),
    executionProfile: z.string(),
    statefulSessions: z.boolean(),
    environmentId: z.string().optional(),
    environmentType: z.string().optional(),
    codeSessionKey: z.string(),
    runtimeSessionHint: z.string().optional(),
  }),
});

it.each([
  { provider: "anthropic", model: models.anthropic },
  { provider: "openAI", model: models.openai },
  { provider: "OpenRouter", model: models.openrouter },
  { provider: "ollama", model: models.ollama },
])(
  "shares the Personal agent VM across ordinary $provider model switches within each conversation",
  async ({ provider, model }) => {
    vi.stubEnv("LIBRECHAT_CODE_DEFAULT_PROFILE", "stateful");

    const providers = {
      anthropicKeyFile: "/fixture/key",
      openaiKeyFile: "/fixture/key",
      openrouterKeyFile: "/fixture/key",
      ollamaUrl: "http://127.0.0.1:11434",
    };
    const configured = await configureProviders(
      providers,
      async () => "fixture-key",
    );
    const definition = configuredPersonalAgents(providers, models).find(
      (agent) => agent.provider === provider,
    );

    if (definition === undefined) {
      throw new Error(`No Personal agent is configured for ${provider}`);
    }

    const owner = { userId: "fixture-user", email: "fixture@example.com" };
    const saved = personalAgentData(definition, owner, {
      instructions: "Personal instructions",
      servers: ["workspace"],
      fileSearch: true,
    });
    const environments = [
      {
        id: CODE_ENVIRONMENT_ID,
        name: "Conversation VM",
        type: "managed",
        baseURL: "http://127.0.0.1:3195/v1",
        default: true,
      },
    ];
    const params = {
      codeExecutionAvailable: true,
      statefulSessionsAvailable: true,
      allowedStatefulCodeEnvironments: ["conversation"],
      environments,
      userId: owner.userId,
    };
    const conversations = [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-4000-8000-000000000002",
    ];
    const sessionKeys = await Promise.all(
      conversations.map(async (conversationId) => {
        const personal = codeRoute.parse(
          api.resolveAgentCodeExecution({
            ...params,
            conversationId,
            agent: saved,
          }),
        );
        const ordinary = await Promise.all(
          [model, `${model}-alternative`].map(async (selected) => {
            const agent = await api.loadEphemeralAgent(
              {
                req: {
                  user: { id: owner.userId },
                  body: { ephemeralAgent: { execute_code: true } },
                  config: { endpoints: configured.endpoints },
                },
                endpoint: provider,
                model_parameters: { model: selected },
              },
              {
                getAgent: async () => null,
                getMCPServerTools: async () => null,
              },
            );

            return codeRoute.parse(
              api.resolveAgentCodeExecution({
                ...params,
                conversationId,
                agent,
              }),
            );
          }),
        );

        expect({
          profile: personal.context.executionProfile,
          scope: personal.statefulCodeEnvironment,
          stateful: personal.statefulSessions,
          environment: personal.context.environmentId,
          ordinary,
        }).toStrictEqual({
          profile: "stateful",
          scope: "conversation",
          stateful: true,
          environment: CODE_ENVIRONMENT_ID,
          ordinary: [personal, personal],
        });
        return personal.context.codeSessionKey;
      }),
    );

    expect(new Set(sessionKeys).size).toBe(conversations.length);
  },
);

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
