import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";

export default function openaiContextProfileFixture(pi: ExtensionAPI): void {
  pi.on("input", (_event, ctx) => {
    const active = ctx.model;
    assert.ok(active, "The managed profile should have an active model");
    const registryModel = ctx.modelRegistry.find("openai", active.id);
    assert.ok(registryModel, "The model should remain in Pi's registry");
    assert.deepEqual(
      {
        model: structuredClone(active),
        registryWindow: registryModel.contextWindow,
        usageWindow: ctx.getContextUsage()?.contextWindow,
        registered:
          ctx.modelRegistry.getRegisteredNativeProvider("openai") !== undefined,
      },
      {
        model: structuredClone(registryModel),
        registryWindow: 510_000,
        usageWindow: 510_000,
        registered: true,
      },
    );
    return { action: "handled" };
  });
}
