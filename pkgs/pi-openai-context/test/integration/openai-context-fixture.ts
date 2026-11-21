import type { Api, Model } from "@earendil-works/pi-ai";
import {
  getAgentDir,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { readScenario } from "./openai-context-scenarios.ts";

const modeFlag = "context-probe-mode";

export default function openaiContextFixture(pi: ExtensionAPI): void {
  pi.registerFlag(modeFlag, { type: "string" });
  const authPath = join(getAgentDir(), "auth.json");
  const modelsPath = join(getAgentDir(), "models.json");
  let baseline: Model<Api> | undefined;
  let expectedContext: number | undefined;
  let explicit = false;
  let entriesBeforeOverride: number | undefined;
  let overlappingRefresh: Promise<unknown> | undefined;

  pi.on("session_start", (_event, ctx) => {
    assert.ok(ctx.model);
    baseline = ctx.modelRegistry.find("openai", ctx.model.id);
    assert.ok(baseline);
    const scenario = readScenario(pi.getFlag(modeFlag));
    expectedContext = scenario.expectedWindow ?? baseline.contextWindow;
    explicit = false;
    if (scenario.expectedWindow !== undefined) {
      assert.notEqual(
        baseline.contextWindow,
        expectedContext,
        "The fixture window must differ from Pi’s registry window",
      );
    }
    if (scenario.catalogue === "delayed") {
      // A refresh of Pi's registry can overlap with the extension's account request.
      overlappingRefresh = ctx.modelRegistry.refresh({
        allowNetwork: false,
        providers: ["openai"],
      });
    }
  });
  pi.on("model_select", (event, ctx) => {
    baseline = ctx.modelRegistry.find(event.model.provider, event.model.id);
  });

  function verifyContext(ctx: ExtensionContext): void {
    assert.ok(baseline !== undefined);
    const registry = ctx.modelRegistry.find("openai", baseline.id);
    assert.deepEqual(
      {
        active: ctx.model,
        usageWindow: ctx.getContextUsage()?.contextWindow,
        registry,
        registered: ctx.modelRegistry
          .getRegisteredProviderIds()
          .includes("openai"),
        unknown: ctx.modelRegistry.find("openai", "unknown-model"),
      },
      {
        active: {
          ...baseline,
          contextWindow: expectedContext,
          maxTokens: explicit ? 40_000 : baseline.maxTokens,
        },
        usageWindow: expectedContext,
        registry: baseline,
        registered: false,
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
