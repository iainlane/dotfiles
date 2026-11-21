import type { Model } from "@earendil-works/pi-ai";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import {
  adjustContext,
  readContextPolicy,
  restoreContext,
} from "#openai-context/model.ts";

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
