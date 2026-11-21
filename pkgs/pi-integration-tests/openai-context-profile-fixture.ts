import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";

export default function openaiContextProfileFixture(pi: ExtensionAPI): void {
  pi.on("input", (_event, ctx) => {
    const active = ctx.model;
    assert.ok(active, "The managed profile should have an active model");
    const base = ctx.modelRegistry.find("openai", active.id);
    assert.ok(base, "The model should remain in Pi's registry");
    assert.notEqual(active.contextWindow, base.contextWindow);
    assert.deepEqual(
      {
        model: active,
        usageWindow: ctx.getContextUsage()?.contextWindow,
        registered: ctx.modelRegistry
          .getRegisteredProviderIds()
          .includes("openai"),
      },
      {
        model: { ...base, contextWindow: 510_000 },
        usageWindow: 510_000,
        registered: false,
      },
    );
    return { action: "handled" };
  });
}
