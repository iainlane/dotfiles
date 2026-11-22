import {
  isModelType,
  type Api,
  type Credential,
  type Model,
  type Provider,
  type RefreshModelsContext,
} from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { ContextCatalogue } from "./catalogue.ts";
import { openaiBaseUrl, openaiProvider } from "./catalogue-client.ts";
import { classifyCredential } from "./credential.ts";
import {
  adjustContext,
  contextPolicy,
  isOpenAIResponsesModel,
  type ModelConfigRead,
  readModelConfig,
  restoreContext,
} from "./model.ts";

type Registry = ExtensionContext["modelRegistry"];
type Windows = ContextCatalogue["windows"];

interface Projection {
  config: ModelConfigRead;
  windows: Windows;
  clientId: string | undefined;
}

export class OpenAIContextProvider {
  readonly provider: Provider;
  private readonly modelsPath: string;
  private readonly catalogue: ContextCatalogue;
  private projection: Projection | undefined;

  constructor(
    parent: Provider,
    modelsPath: string,
    catalogue: ContextCatalogue,
  ) {
    this.modelsPath = modelsPath;
    this.catalogue = catalogue;
    const filterAllModels = parent.filterAllModels?.bind(parent);
    this.provider = {
      ...parent,
      refreshModels: async (context) => {
        await parent.refreshModels?.(context);
        await this.restoreWindows(context);
      },
      getModels: () => parent.getModels().map((model) => this.project(model)),
      getAllModels: () =>
        (parent.getAllModels?.() ?? parent.getModels()).map((model) =>
          isModelType(model, "chat") ? this.project(model) : model,
        ),
      filterModels: (models, credential) => {
        const available = parent.filterModels?.(models, credential) ?? models;
        return this.matchesAccount(credential)
          ? available
          : available.map((model) => restoreContext(model, "account"));
      },
      filterAllModels:
        filterAllModels &&
        ((models, credential) => {
          const available = filterAllModels(models, credential);
          return this.matchesAccount(credential)
            ? available
            : available.map((model) =>
                isModelType(model, "chat")
                  ? restoreContext(model, "account")
                  : model,
              );
        }),
    };
  }

  async loadSavedWindows(): Promise<void> {
    const config = await readModelConfig(this.modelsPath);
    if (
      config.kind !== "available" ||
      (config.openai?.baseUrl ?? this.provider.baseUrl) !== openaiBaseUrl
    ) {
      return;
    }
    const clientId = await this.catalogue.checkRegistration();
    if (clientId !== undefined) {
      this.projection = {
        config,
        windows: this.catalogue.windowsFor(clientId),
        clientId,
      };
    }
  }

  manages(registry: Registry): boolean {
    return (
      registry.getRegisteredNativeProvider(openaiProvider) === this.provider
    );
  }

  acceptsAccountWindows(registry: Registry): boolean {
    if (
      !this.manages(registry) ||
      registry.getProvider(openaiProvider)?.baseUrl !== openaiBaseUrl ||
      registry.getProviderAuthStatus(openaiProvider).source !== "stored"
    ) {
      return false;
    }
    const model = this.provider
      .getModels()
      .find((entry) => isOpenAIResponsesModel(entry));
    return model !== undefined && registry.isUsingOAuth(model);
  }

  async synchronize(
    registry: Registry,
    windows: Windows,
    isCurrent: () => boolean,
  ): Promise<void> {
    if (!isCurrent() || !this.manages(registry)) {
      return;
    }
    const config = await readModelConfig(this.modelsPath);
    if (
      !isCurrent() ||
      !this.manages(registry) ||
      this.isSynchronized(config, windows)
    ) {
      return;
    }
    const { errors } = await registry.refresh({
      allowNetwork: false,
      providers: [openaiProvider],
    });
    const error = errors.get(openaiProvider);
    if (error !== undefined && isCurrent()) {
      throw new Error("Pi could not refresh the OpenAI model registry.", {
        cause: error,
      });
    }
  }

  unregister(registry: Registry): void {
    if (this.manages(registry)) {
      registry.unregisterProvider(openaiProvider);
    }
  }

  private isSynchronized(config: ModelConfigRead, windows: Windows): boolean {
    const previous = this.projection;
    if (previous?.config.kind !== config.kind) {
      return false;
    }
    if (
      config.kind === "available" &&
      previous.config.kind === "available" &&
      config.content !== previous.config.content
    ) {
      return false;
    }
    const published = previous.windows;
    return (
      published === windows ||
      (windows !== undefined &&
        published?.size === windows.size &&
        [...windows].every(([id, window]) => published.get(id) === window))
    );
  }

  private async restoreWindows(context: RefreshModelsContext): Promise<void> {
    // Pi passes the stored credential in the cache phase, even for a public remote catalogue.
    if (context.allowNetwork || context.signal.aborted) {
      return;
    }
    const config = await readModelConfig(this.modelsPath);
    const credential = classifyCredential(context.credential);
    let windows: Windows;
    let clientId: string | undefined;
    if (
      config.kind === "available" &&
      context.baseUrl === openaiBaseUrl &&
      credential.status === "present"
    ) {
      await this.catalogue.checkRegistration();
      clientId = credential.credential.clientId;
      windows = this.catalogue.windowsFor(clientId);
    }
    await context.publish({
      update: () => {
        this.projection = { config, windows, clientId };
      },
    });
  }

  private matchesAccount(credential: Credential | undefined): boolean {
    const stored = classifyCredential(credential);
    return (
      stored.status === "present" &&
      stored.credential.clientId === this.projection?.clientId
    );
  }

  private project(model: Model<Api>): Model<Api> {
    const projection = this.projection;
    if (
      projection?.config.kind !== "available" ||
      !isOpenAIResponsesModel(model) ||
      contextPolicy(projection.config, model.id).kind !== "automatic"
    ) {
      return model;
    }
    const contextWindow = projection.windows?.get(model.id);
    if (contextWindow === undefined) {
      return model;
    }
    const maxTokens =
      projection.config.openai?.modelOverrides?.[model.id]?.maxTokens;
    const baseline = maxTokens === undefined ? model : { ...model, maxTokens };
    return (
      adjustContext(baseline, { contextWindow }, "account", "registry") ?? model
    );
  }
}
