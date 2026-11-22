import {
  getAgentDir,
  ModelRuntime,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
import { ContextCatalogue } from "./catalogue.ts";
import {
  openaiBaseUrl,
  openaiProvider,
  readAccountWindows,
} from "./catalogue-client.ts";
import { ContextController, type ContextModelSession } from "./controller.ts";
import { readChatGptCredential } from "./credential.ts";
import { readContextPolicy } from "./model.ts";
import { OpenAIContextProvider } from "./provider.ts";

function modelSession(
  ctx: ExtensionContext,
  provider: OpenAIContextProvider,
): ContextModelSession {
  const registry = ctx.modelRegistry;
  return {
    get model() {
      return ctx.model;
    },
    isIdle: () => ctx.isIdle(),
    managesModel(id) {
      return (
        provider.manages(registry) &&
        registry.find("openai", id)?.baseUrl === openaiBaseUrl
      );
    },
    acceptsAccountWindows: () => provider.acceptsAccountWindows(registry),
    publishAccountWindows: (windows, isCurrent) =>
      provider.synchronize(registry, windows, isCurrent),
    async resolveAccountToken() {
      const auth = await registry.getProviderAuth(openaiProvider);
      return auth?.source === "OAuth" ? auth.auth.apiKey : undefined;
    },
  };
}

export default async function openaiContextExtension(
  pi: ExtensionAPI,
): Promise<void> {
  const agentDir = getAgentDir();
  const authPath = join(agentDir, "auth.json");
  const modelsPath = join(agentDir, "models.json");
  // The CLI runtime applies models.json to the registered wrapper.
  const runtime = await ModelRuntime.create({
    modelsPath: null,
    refreshOnCreate: false,
  });
  const parent = runtime.getProvider(openaiProvider);
  if (parent === undefined) {
    return;
  }
  const catalogue = new ContextCatalogue({
    path: join(agentDir, "openai-context-cache.json"),
    readCredential: () => readChatGptCredential(authPath),
    readWindows: readAccountWindows,
    offline: process.env.PI_OFFLINE !== undefined,
  });
  const provider = new OpenAIContextProvider(parent, modelsPath, catalogue);
  pi.registerProvider(provider.provider);
  const controller = new ContextController({
    catalogue,
    controls: pi,
    readPolicy: (id) => readContextPolicy(modelsPath, id),
  });

  pi.on("session_start", (_event, ctx) => {
    controller.start();
    return controller.apply(modelSession(ctx, provider), "selection");
  });
  pi.on("model_select", (_event, ctx) =>
    controller.apply(modelSession(ctx, provider), "selection"),
  );
  pi.on("input", (_event, ctx) =>
    controller.apply(modelSession(ctx, provider), "input"),
  );
  pi.on("before_agent_start", (_event, ctx) =>
    controller.apply(modelSession(ctx, provider), "run-start"),
  );
  pi.on("session_shutdown", (_event, ctx) => {
    controller.cancel();
    provider.unregister(ctx.modelRegistry);
  });

  const showStatus = async (_args: string, ctx: ExtensionContext) => {
    ctx.ui.notify(await controller.status(modelSession(ctx, provider)), "info");
  };
  pi.registerCommand("openai-context", {
    description: "Show or refresh OpenAI context limits",
    handler: async (args, ctx) => {
      const action = args.trim();
      if (action === "") {
        await showStatus(args, ctx);
        return;
      }
      if (action !== "refresh") {
        ctx.ui.notify("Usage: /openai-context [refresh]", "warning");
        return;
      }

      const result = await controller.refresh(modelSession(ctx, provider));
      if (result === undefined) {
        return;
      }
      if ("error" in result) {
        ctx.ui.notify(result.error, "warning");
        return;
      }
      ctx.ui.notify("ChatGPT account catalogue refreshed.", "info");
    },
  });
  pi.registerCommand("openai-context-status", {
    description:
      "Show the active OpenAI context window and account refresh status",
    handler: showStatus,
  });
}
