import {
  getAgentDir,
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
      provider.publish(registry, windows, isCurrent),
    async resolveAccountToken() {
      const auth = await registry.getProviderAuth(openaiProvider);
      return auth?.source === "OAuth" ? auth.auth.apiKey : undefined;
    },
  };
}

export default function openaiContextExtension(pi: ExtensionAPI): void {
  const agentDir = getAgentDir();
  const authPath = join(agentDir, "auth.json");
  const modelsPath = join(agentDir, "models.json");
  const provider = new OpenAIContextProvider(modelsPath);
  const controller = new ContextController({
    catalogue: new ContextCatalogue({
      path: join(agentDir, "openai-context-cache.json"),
      readCredential: () => readChatGptCredential(authPath),
      readWindows: readAccountWindows,
      offline: process.env.PI_OFFLINE !== undefined,
    }),
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
  pi.on("session_shutdown", () => {
    controller.cancel();
    provider.unregister();
  });

  pi.registerCommand("openai-context-status", {
    description:
      "Show the active OpenAI context window and account refresh status",
    handler: async (_args, ctx) => {
      ctx.ui.notify(
        await controller.status(modelSession(ctx, provider)),
        "info",
      );
    },
  });
}
