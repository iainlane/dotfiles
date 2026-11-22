import type { Api, Model } from "@earendil-works/pi-ai";
import {
  getAgentDir,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { inactiveModelId, readScenario } from "./openai-context-scenarios.ts";

const modeFlag = "context-probe-mode";

export default function openaiContextFixture(pi: ExtensionAPI): void {
  pi.registerFlag(modeFlag, { type: "string" });
  const authPath = join(getAgentDir(), "auth.json");
  const modelsPath = join(getAgentDir(), "models.json");
  let baseline: Model<Api> | undefined;
  let expectedContext: number | undefined;
  let expectedAccountWindow: number | undefined;
  let inactiveBaseline: Model<Api> | undefined;
  let explicit = false;
  let entriesBeforeOverride: number | undefined;
  let overlappingRefresh: Promise<unknown> | undefined;

  pi.on("session_start", (_event, ctx) => {
    if (pi.getFlag(modeFlag) === "warm") {
      return;
    }
    if (pi.getFlag(modeFlag) === "foreign") {
      pi.registerProvider("openai", { name: "Fixture OpenAI" });
    }
    assert.ok(ctx.model);
    baseline ??= structuredClone(
      ctx.modelRegistry.find("openai", ctx.model.id),
    );
    assert.ok(baseline);
    const scenario = readScenario(pi.getFlag(modeFlag));
    inactiveBaseline ??= structuredClone(
      ctx.modelRegistry.find("openai", inactiveModelId),
    );
    assert.ok(inactiveBaseline);
    expectedContext = scenario.expectedWindow ?? baseline.contextWindow;
    expectedAccountWindow =
      pi.getFlag(modeFlag) === "override" ? 510_000 : scenario.expectedWindow;
    explicit = false;
    if (scenario.catalogue === "delayed") {
      // A refresh of Pi's registry can overlap with the extension's account request.
      overlappingRefresh = ctx.modelRegistry.refresh({
        allowNetwork: false,
        providers: ["openai"],
      });
    }
  });
  pi.on("model_select", (event, ctx) => {
    baseline = structuredClone(
      ctx.modelRegistry.find(event.model.provider, event.model.id),
    );
  });

  function verifyContext(ctx: ExtensionContext): void {
    assert.ok(baseline !== undefined && inactiveBaseline !== undefined);
    const registry = ctx.modelRegistry.find("openai", baseline.id);
    const inactive = ctx.modelRegistry.find("openai", inactiveModelId);
    assert.deepEqual(
      {
        active: structuredClone(ctx.model),
        usageWindow: ctx.getContextUsage()?.contextWindow,
        registryWindow: registry?.contextWindow,
        inactive: structuredClone(inactive),
        registered:
          ctx.modelRegistry.getRegisteredNativeProvider("openai") !== undefined,
        foreignName:
          ctx.modelRegistry.getRegisteredProviderConfig("openai")?.name,
        unknown: ctx.modelRegistry.find("openai", "unknown-model"),
      },
      {
        active: {
          ...baseline,
          contextWindow: expectedContext,
          maxTokens: explicit ? 40_000 : baseline.maxTokens,
        },
        usageWindow: expectedContext,
        registryWindow: expectedContext,
        inactive: {
          ...inactiveBaseline,
          contextWindow:
            expectedAccountWindow ?? inactiveBaseline.contextWindow,
        },
        registered: pi.getFlag(modeFlag) !== "foreign",
        foreignName:
          pi.getFlag(modeFlag) === "foreign" ? "Fixture OpenAI" : undefined,
        unknown: undefined,
      },
    );
  }

  pi.registerCommand("check-openai-context", {
    handler: async (_args, ctx) => {
      await overlappingRefresh;
      verifyContext(ctx);
      if (entriesBeforeOverride !== undefined) {
        const changes = ctx.sessionManager
          .getEntries()
          .slice(entriesBeforeOverride)
          .flatMap<{ model: string } | { thinking: string }>((entry) =>
            entry.type === "model_change"
              ? [{ model: entry.modelId }]
              : entry.type === "thinking_level_change"
                ? [{ thinking: entry.thinkingLevel }]
                : [],
          );
        assert.deepEqual(changes, [
          { model: ctx.model?.id },
          { thinking: "low" },
          { thinking: "high" },
        ]);
        entriesBeforeOverride = undefined;
      }
    },
  });

  pi.registerCommand("reload-openai-context", {
    handler: async (_args, ctx) => {
      await ctx.reload();
    },
  });

  pi.registerCommand("openai-context-programmatic-turn", {
    handler: () => {
      pi.sendMessage(
        {
          customType: "context-probe",
          content: "Probe the programmatic Responses stream",
          display: false,
        },
        { triggerTurn: true },
      );
      return Promise.resolve();
    },
  });

  pi.registerCommand("add-context-override", {
    handler: async (_args, ctx) => {
      entriesBeforeOverride = ctx.sessionManager.getEntries().length;
      assert.ok(baseline);
      expectedContext = 420_000;
      explicit = true;
      await writeFile(
        modelsPath,
        JSON.stringify({
          providers: {
            openai: {
              modelOverrides: {
                [baseline.id]: {
                  contextWindow: expectedContext,
                  maxTokens: 40_000,
                },
              },
            },
          },
        }),
      );
    },
  });

  pi.registerCommand("remove-context-override", {
    handler: async () => {
      await writeFile(modelsPath, '{"providers":{}}');
      explicit = false;
      expectedContext = 510_000;
    },
  });

  pi.registerCommand("change-chatgpt-registration", {
    handler: async () => {
      expectedContext = 620_000;
      expectedAccountWindow = 620_000;
      await writeFile(
        authPath,
        JSON.stringify({
          openai: {
            type: "oauth",
            access: "rotated",
            refresh: "fixture",
            clientId: "another-registration",
            expires: 4_102_444_800_000,
          },
        }),
      );
    },
  });

  pi.registerCommand("rotate-chatgpt-token", {
    handler: async () => {
      await writeFile(
        authPath,
        JSON.stringify({
          openai: {
            type: "oauth",
            access: "rotated",
            refresh: "fixture",
            clientId: "fixture",
            expires: 4_102_444_800_000,
          },
        }),
      );
    },
  });
}
