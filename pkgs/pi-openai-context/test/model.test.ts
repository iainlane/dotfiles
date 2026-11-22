import type { Model } from "@earendil-works/pi-ai";
import { DefaultResourceLoader } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { writeCatalogue } from "#openai-context/cache.ts";
import openaiContextExtension from "#openai-context/extension.ts";
import {
  adjustContext,
  readContextPolicy,
  restoreContext,
} from "#openai-context/model.ts";

it("registers cached context limits before Pi refreshes the model runtime", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pi-openai-startup-"));
  vi.stubEnv("PI_CODING_AGENT_DIR", directory);
  try {
    const credential = {
      type: "oauth",
      access: "fixture",
      refresh: "fixture",
      expires: 4_102_444_800_000,
      clientId: "fixture",
    } as const;
    const modelId = "gpt-6.1-sol";
    await Promise.all([
      writeFile(
        join(directory, "auth.json"),
        JSON.stringify({ openai: credential }),
      ),
      writeCatalogue(join(directory, "openai-context-cache.json"), {
        grant: createHash("sha256").update(credential.clientId).digest("hex"),
        refreshAfter: Date.now() + 60_000,
        contextWindows: new Map([[modelId, 530_000]]),
      }),
    ]);
    const loader = new DefaultResourceLoader({
      cwd: directory,
      agentDir: directory,
      extensionFactories: [openaiContextExtension],
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
    });
    await loader.reload();
    const { runtime, errors } = loader.getExtensions();
    expect(errors).toStrictEqual([]);
    const provider = runtime.pendingNativeProviderRegistrations.find(
      (registration) => registration.provider.id === "openai",
    )?.provider;
    if (provider === undefined) {
      throw new Error("The extension did not register the OpenAI provider.");
    }
    const model = provider.getModels().find((entry) => entry.id === modelId);
    if (model === undefined) {
      throw new Error(`The OpenAI provider did not include ${modelId}.`);
    }
    const apiKey = { type: "api_key", key: "fixture" } as const;
    expect({
      initial: model.contextWindow,
      oauth: provider.filterModels?.([model], credential)[0]?.contextWindow,
      apiKey: provider.filterModels?.([model], apiKey)[0]?.contextWindow,
      otherLogin: provider.filterModels?.([model], {
        ...credential,
        clientId: "another-login",
      })[0]?.contextWindow,
    }).toStrictEqual({
      initial: 530_000,
      oauth: 530_000,
      apiKey: 272_000,
      otherLogin: 272_000,
    });
  } finally {
    vi.unstubAllEnvs();
    await rm(directory, { force: true, recursive: true });
  }
});

it("applies only windows with room for input", () => {
  const base: Model<"openai-responses"> = {
    id: "fixture",
    name: "Fixture model",
    provider: "openai",
    api: "openai-responses",
    baseUrl: "https://api.openai.com/v1",
    reasoning: true,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 120_000,
    maxTokens: 32_000,
  };
  const advertised = base.maxTokens + base.contextWindow;
  const adjusted = adjustContext(
    base,
    { contextWindow: advertised },
    "account",
  );
  expect(adjusted && restoreContext(adjusted)).toStrictEqual(base);
  expect([
    adjustContext(base, { contextWindow: base.contextWindow }, "account"),
    adjustContext(base, { contextWindow: base.maxTokens }, "account"),
    adjusted,
  ]).toStrictEqual([base, undefined, { ...base, contextWindow: advertised }]);
});

it("recognises explicit context settings in the current models.json", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pi-openai-models-"));
  const path = join(directory, "models.json");
  try {
    const absent = (await readContextPolicy(path, "sol")).kind;
    await writeFile(
      path,
      `{
      // A model's configured window wins.
      "providers": { "openai": {
        "modelOverrides": { "sol": { "contextWindow": 400000 }, "other": { "name": "test // label" } },
        "models": [{ "id": "custom" },],
      }, }
    }`,
    );
    const configured = await Promise.all(
      ["sol", "other", "custom"].map(
        async (id) => (await readContextPolicy(path, id)).kind,
      ),
    );
    await writeFile(path, "{}");
    const invalid = (await readContextPolicy(path, "sol")).kind;
    await writeFile(path, '{"providers":{}}');
    const removed = (await readContextPolicy(path, "sol")).kind;
    expect({ absent, configured, invalid, removed }).toStrictEqual({
      absent: "automatic",
      configured: ["override", "automatic", "configured"],
      invalid: "unavailable",
      removed: "automatic",
    });
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});
