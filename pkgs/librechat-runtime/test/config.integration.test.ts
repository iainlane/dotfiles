import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { hostManifestSchema } from "../src/manifest.ts";
import {
  configureChatPrompts,
  configureInterface,
  configureProviders,
  persistentSecret,
  writePrivateJson,
} from "../src/config.ts";

let directory: string;

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "librechat-config-"));
});

afterEach(async () => {
  await rm(directory, { recursive: true, force: true });
});

describe("provider configuration", () => {
  it("omits every unset provider", async () => {
    expect(await configureProviders({})).toStrictEqual({
      endpoints: { custom: [] },
      environment: { ENDPOINTS: "agents" },
    });
  });

  it("enables only configured providers and reads runtime keys", async () => {
    const key = join(directory, "key");

    await writeFile(key, "test-key\n");

    expect(
      await configureProviders({
        ollamaUrl: "http://127.0.0.1:11434",
        anthropicKeyFile: key,
        openrouterKeyFile: key,
        openaiKeyFile: key,
      }),
    ).toStrictEqual({
      endpoints: {
        custom: [
          {
            name: "Ollama",
            apiKey: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            models: { default: [], fetch: true },
            modelDisplayLabel: "Ollama",
          },
          {
            name: "OpenRouter",
            apiKey: "${OPENROUTER_API_KEY}",
            baseURL: "https://openrouter.ai/api/v1",
            models: { default: [], fetch: true },
            modelDisplayLabel: "OpenRouter",
          },
        ],
      },
      environment: {
        ENDPOINTS: "agents,openAI,anthropic,custom",
        OPENAI_API_KEY: "test-key",
        ANTHROPIC_API_KEY: "test-key",
        OPENROUTER_API_KEY: "test-key",
      },
    });
  });

  it.each(["absent", "empty", "multiline"])(
    "rejects a configured %s key",
    async (kind) => {
      const key = join(directory, "key");

      if (kind !== "absent") {
        await writeFile(key, kind === "empty" ? "\n" : "first\nsecond\n");
      }

      await expect(
        configureProviders({ anthropicKeyFile: key }),
      ).rejects.toThrow("Anthropic");
    },
  );
});

it("publishes the ordinary-chat instructions as a managed library default", () => {
  expect(
    configureChatPrompts(
      hostManifestSchema.shape.chatPrompt.parse("General chat instructions\n"),
    ),
  ).toStrictEqual({
    library: [
      {
        id: "general-assistant",
        name: "General assistant",
        description: "A general assistant for everyday conversations.",
        prompt: "General chat instructions\n",
      },
    ],
    defaultChatPrompt: "general-assistant",
  });
});

it.each([
  { retrieval: false, tools: ["execute_code", "skills"], servers: [] },
  {
    retrieval: true,
    tools: ["execute_code", "skills", "file_search"],
    servers: ["git", "cloudflare"],
  },
])(
  "enables code and skills in new ordinary chats (retrieval $retrieval)",
  ({ retrieval, tools, servers }) => {
    expect(configureInterface(retrieval, servers)).toStrictEqual({
      modelSelect: true,
      defaultEnabledTools: tools,
      defaultMCPServers: servers,
    });
  },
);

it("keeps generated credentials stable and private across starts", async () => {
  const file = join(directory, "secret");

  const first = await persistentSecret(file);

  const second = await persistentSecret(file);

  expect({
    same: first === second,
    bytes: first.length,
    mode: (await stat(file)).mode & 0o777,
  }).toStrictEqual({ same: true, bytes: 64, mode: 0o600 });
});

it("writes complete private runtime configuration", async () => {
  const file = join(directory, "runtime.json");

  await writePrivateJson(file, { key: "first" });

  await writePrivateJson(file, { key: "second" });

  const content: unknown = JSON.parse(await readFile(file, "utf8"));

  expect({
    content,
    mode: (await stat(file)).mode & 0o777,
  }).toStrictEqual({ content: { key: "second" }, mode: 0o600 });
});
