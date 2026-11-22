import {
  isModelType,
  type Api,
  type Model,
  type Provider,
} from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { openaiBaseUrl, openaiProvider } from "./catalogue-client.ts";
import {
  adjustContext,
  contextPolicy,
  isOpenAIResponsesModel,
  readModelConfig,
} from "./model.ts";

type Registry = ExtensionContext["modelRegistry"];

interface Registration {
  registry: Registry;
  provider: Provider;
  parent: Provider;
  windows: ReadonlyMap<string, number>;
  config: string | undefined;
}

export class OpenAIContextProvider {
  private readonly modelsPath: string;
  private registration: Registration | undefined;

  constructor(modelsPath: string) {
    this.modelsPath = modelsPath;
  }

  manages(registry: Registry): boolean {
    return (
      this.owns(registry) ||
      !registry.getRegisteredProviderIds().includes(openaiProvider)
    );
  }

  acceptsAccountWindows(registry: Registry): boolean {
    const provider = registry.getProvider(openaiProvider);
    if (
      !this.manages(registry) ||
      provider?.baseUrl !== openaiBaseUrl ||
      provider.auth.oauth?.isSubscription !== true
    ) {
      return false;
    }
    const model = provider
      .getModels()
      .find((entry) => isOpenAIResponsesModel(entry));
    return model !== undefined && modelUsesStoredOAuth(registry, model);
  }

  async publish(
    registry: Registry,
    windows: ReadonlyMap<string, number> | undefined,
    isCurrent: () => boolean,
  ): Promise<void> {
    if (!isCurrent()) {
      return;
    }
    if (windows === undefined || !this.acceptsAccountWindows(registry)) {
      this.unregister();
      return;
    }

    const config = await readModelConfig(this.modelsPath);
    if (!isCurrent()) {
      return;
    }
    if (config.kind === "unavailable") {
      this.unregister();
      return;
    }

    let previous = this.owns(registry) ? this.registration : undefined;
    const previousWindows = previous?.windows;
    if (previous !== undefined && previous.config !== config.content) {
      await registry.refresh({
        allowNetwork: false,
        providers: [openaiProvider],
      });
      if (!isCurrent()) {
        return;
      }
      this.unregister();
      previous = undefined;
    } else if (
      previousWindows === windows ||
      (previousWindows?.size === windows.size &&
        [...windows].every(
          ([id, window]) => previousWindows.get(id) === window,
        ))
    ) {
      return;
    }

    if (!this.acceptsAccountWindows(registry)) {
      return;
    }
    const parent = previous?.parent ?? registry.getProvider(openaiProvider);
    if (parent === undefined) {
      return;
    }

    const project = (model: Model<Api>): Model<Api> => {
      if (
        !isOpenAIResponsesModel(model) ||
        !modelUsesStoredOAuth(registry, model) ||
        contextPolicy(config, model.id).kind !== "automatic"
      ) {
        return model;
      }
      const contextWindow = windows.get(model.id);
      if (contextWindow === undefined) {
        return model;
      }
      return (
        adjustContext(model, { contextWindow }, "account", "registry") ?? model
      );
    };
    if (!parent.getModels().some((model) => project(model) !== model)) {
      this.unregister();
      return;
    }
    const provider: Provider = {
      ...parent,
      getModels: () => parent.getModels().map((model) => project(model)),
      getAllModels: () =>
        (parent.getAllModels?.() ?? parent.getModels()).map((model) =>
          isModelType(model, "chat") ? project(model) : model,
        ),
    };
    // pi.registerProvider also replaces the active model without a model_select event.
    registry.registerProvider(provider);
    this.registration = {
      registry,
      provider,
      parent,
      windows,
      config: config.content,
    };
  }

  unregister(): void {
    const registration = this.registration;
    if (registration !== undefined && this.owns(registration.registry)) {
      registration.registry.unregisterProvider(openaiProvider);
    }
    this.registration = undefined;
  }

  private owns(registry: Registry): boolean {
    return (
      this.registration?.registry === registry &&
      registry.getRegisteredNativeProvider(openaiProvider) ===
        this.registration.provider
    );
  }
}

function modelUsesStoredOAuth(registry: Registry, model: Model<Api>): boolean {
  return (
    registry.getProviderAuthStatus(openaiProvider).source === "stored" &&
    registry.isUsingOAuth(model)
  );
}
